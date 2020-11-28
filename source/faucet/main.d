/*******************************************************************************

    Entry point for the faucet tool

    The tool currently contains a basic version of a transaction generator.

    Copyright:
        Copyright (c) 2020 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module faucet.main;

import agora.api.FullNode;
import agora.common.Amount;
import agora.common.crypto.Key;
import agora.common.Serializer;
import agora.common.Types;
import agora.consensus.data.genesis.Test;
import agora.consensus.data.Transaction;
import agora.consensus.data.UTXO;
import agora.consensus.state.UTXOSet;
import agora.utils.Test;

import std.algorithm;
import std.random;
import std.range;
import std.stdio;

import core.time;

import vibe.core.core;
import vibe.core.log;
import vibe.web.rest;

/// Configuration parameter for Faucet
private struct Config
{
    /// How frequently we run our periodic task
    static immutable interval = 15.seconds;

    /// How many transactions we send per task run
    static immutable count = 15;
}

/// Holds the state of our application and contains update methods
private struct State
{
    /// The UTXO set at `this.known`
    private TestUTXOSet utxos;
    /// The most up-to-date block we know about
    private Height known;

    /// Update the UTXO set and the `known` height
    private bool update (API client, Height from) @safe
    {
        const height = client.getBlockHeight();
        if (from >= height + 1)
        {
            if (from > height + 1)
                logError("Agora reported a Height of %s but we are at %s", height, this.known);
            return false;
        }

        const blocks = client.getBlocksFrom(from, cast(uint) (height - from + 1));
        logInfo("Updating state: blocks [%s .. %s] (%s)", from, height, blocks.length);
        const current_len = this.utxos.storage.length;

        foreach (ref b; blocks)
            foreach (ref tx; b.txs)
                this.utxos.updateUTXOCache(tx, b.header.height);

        // Use signed arithmetic to avoid negative values wrapping around
        const long delta = (cast(long) this.utxos.storage.length) - current_len;
        logInfo("UTXO delta: %s", delta);
        this.known = blocks[$ - 1].header.height;

        return true;
    }
}

/// Helper function to map an `Output` to a `TxBuilder`
private TxBuilder buildTx (in Output value, in Hash key)
    @safe pure nothrow
{
    return TxBuilder(value.address).attach(value, key);
}

/*******************************************************************************

    Splits the Outputs from `utxo_rng` towards `count` random keys

    The keys are continuous in the `WK.Keys.byRange()` range, but the range
    starts at a random position (no less than `count` before the end).

    Params:
      UR = Range of UTXO and hash tuple with properties
           `key` (hash) and `value` (`Output`)
      count = The number of keys to spread the UTXOs to

    Returns:
      A range of Transactions

*******************************************************************************/

private auto splitTx (UR) (UR utxo_rng, uint count)
{
    static assert (isInputRange!UR);

    return utxo_rng
        .filter!(tup => tup.value.output.value >= Amount(count))
        .map!(tup => buildTx(tup.value.output, tup.key))
        .map!(txb => txb.split(
                  WK.Keys.byRange()
                  .drop(uniform(0, 1378 - count, rndGen))
                  .take(count)
                  .map!(k => k.address))
              .sign()
            );
}

/*******************************************************************************

    Perform state setup and make sure there is enough UTXOs for us to use

    Populate the `state` variable with the current state of node using `client`,
    and create transactions the will spread all spendable transactions from
    the last known block to `count` addresses.

    Params:
      state = The application state
      client = An API instance to connect to a node
      count = The number of keys to spread the transactions to

*******************************************************************************/

public void setup (ref State state, API client, uint count)
{
    state.update(client, Height(0));
    const utxo_len = state.utxos.storage.length;
    immutable size_t WKKeysCount = 1378;

    logInfo("Setting up: height=%s, %s UTXOs found", state.height, utxo_len);
    if (utxo_len < 200)
    {
        assert(utxo_len >= 8);
        state.utxos.storage.byKeyValue().take(8).splitTx(25)
            .each!(tx => client.putTransaction(tx));
    }
}

/*******************************************************************************

    A task called periodically that generates and send transactions to a node

    This function will wait for block 1 to be externalized before doing anything
    (block 1 should be triggered by `setup` if it doesn't exists).

    The amount and size of generated transactions is mostly random,
    and falls within the following boundaries:
    - UTXOs values are between 0.000,001 BOA (1000) and 10% of the total supply;
    - We aim to have a median UTXO amount of 100 BOA (1,000,000,000);
    - We aim to have between 1000 and 10,000,000 active at any time;

    When the UTXO set falls within 10% of our aim, randomness is increased to
    ensure a steady supply of new behaviors.

    Params:
      client = An API instance to connect to a node
      state =  The current state of Faucet

*******************************************************************************/

void send (API client, ref State state)
{
    state.update(client, Height(state.known + 1));
    if (state.known < 1)
        return logInfo("Waiting for setup to be completed");

    logInfo("About to send transactions...");

    // Sort them so we don't iterate multiple time
    // Note: This may cause a lot of memory usage, might need restructuing later
    // Mutable because of https://issues.dlang.org/show_bug.cgi?id=9792
    auto sutxo = state.utxos.values.sort!((a, b) => a.output.value < b.output.value);
    const size = sutxo.length();
    logInfo("\tUTXO set: %d entries", size);

    immutable median = sutxo[size / 2];
    // Should be 500M (5,000,000,000,000,000) for the time being
    immutable sum = sutxo.map!(utxo => utxo.output.value)
        .fold!((a, b) => Amount(a).mustAdd(b))(Amount(0));
    assert(sum == Amount.MaxUnitSupply);
    auto mean = Amount(sum); mean.div(size);

    logInfo("\tMedian: %s, Avg: %s", median, mean);
    logInfo("\tL: %s, H: %s", sutxo[0], sutxo[$-1]);

    foreach (tx; state.utxos.byKeyValue().take(16).splitTx(Config.count))
    {
        client.putTransaction(tx);
        logInfo("Transaction sent: %s", tx);
    }
}

/// Application entry point
int main (string[] args)
{
    static void printHelp ()
    {
        writeln("Usage: ./faucet <address>");
        writeln("Where <address> is a http endpoint, such as 'http://192.168.0.42:8080'");
    }

    if (args.length != 2)
    {
        logInfo("Please enter one value");
        printHelp();
        return 1;
    }

    try
    {
        logInfo("The address of node is %s", args[1]);
        auto node = new RestInterfaceClient!API(args[1]);
        State state;
        state.utxos = new TestUTXOSet();
        state.setup(node, Config.count);
        setTimer(Config.interval, () => send(node, state), true);
        return runEventLoop();
    }
    catch (Exception e)
    {
        logError("Exception while connecting: %s", e);
        printHelp();
        return 1;
    }
}
