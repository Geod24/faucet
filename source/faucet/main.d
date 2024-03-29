/*******************************************************************************

    Entry point for the faucet tool

    The tool currently contains a basic version of a transaction generator.

    Copyright:
        Copyright (c) 2020-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module faucet.main;

import faucet.API;
import faucet.config;
import faucet.stats;
import faucet.server;

import agora.api.FullNode;
import agora.common.Amount;
import agora.common.Ensure;
import agora.common.Set;
import agora.common.ManagedDatabase;
import agora.common.Types;
import agora.consensus.BlockStorage;
import agora.consensus.data.Block;
import agora.consensus.data.genesis.Test;
import agora.consensus.data.Params;
import agora.consensus.data.Transaction;
import agora.consensus.state.Ledger;
import agora.consensus.state.UTXOSet;
import agora.consensus.state.ValidatorSet;
import agora.crypto.Hash;
import agora.crypto.Key;
import agora.script.Signature;
import agora.serialization.Serializer;
import agora.stats.Utils;
import agora.utils.Test;
import agora.utils.TxBuilder;
import agora.script.Lock;
import agora.utils.Log;

import configy.Read;

import std.algorithm;
import std.exception;
import std.file;
import std.functional : toDelegate;
import std.format;
import std.getopt;
import std.path;
import std.random;
import std.range;
import std.stdio;
import std.typecons;

import core.time;

import vibe.core.core;
import vibe.http.fileserver;
import vibe.http.router;
import vibe.http.server;
import vibe.inet.url;
import vibe.web.rest;

/// The keys that will be used for generating transactions
private SecretKey[PublicKey] secret_keys;

/// PublicKeys of validators that Faucet will freeze stakes for
private PublicKey[] validators;

/// Used for better diagnostic
private struct Connection
{
    /// Address we reference
    public Address address;

    /// Object used for communication
    public API api;

    /// Convenience alias
    public alias api this;
}

/*******************************************************************************

    Implementation of the faucet API

    This class implements the business code of the faucet.

*******************************************************************************/

public class Faucet : FaucetAPI
{
    /// General logger instance
    public Logger log;

    /// Ledger instance
    private Ledger ledger;

    /// UTXOs owned by us
    private UTXO[Hash] owned_utxos;

    /// A storage to keep track of UTXOs sent in txs
    private Set!Hash sent_utxos;

    /// Keeps track of the freeze TXs faucet sent
    private Transaction[PublicKey] freeze_txs;

    /// A storage to keep track of used UTXOs
    private UTXO[Hash] used_utxos;

    /// A client object implementing `API`
    private Connection[] clients;

    /// Minimum input value per output
    /// This is to prevent transactions with too little input value to cover the fees.
    private const minInputValuePerOutput = Amount(5_000_000);

    /// Timer on which transactions are generated and send
    public Timer sendTx;

    /// Timer on which we atttempt to update the state
    private Timer updateTimer;

    /// Listener for the user interface, if any
    public HTTPListener webInterface;

    /// Configuration instance
    private Config config;

    /***************************************************************************

        Stats-related fields

        Those fields are used to expose internal statistics about the faucet on
        an HTTP interface that is ultimately queried by a Prometheus server.

    ***************************************************************************/

    /// Ditto
    protected StatsServer stats_server;

    /// Ditto
    protected FaucetStats faucet_stats;

    /// Ditto
    mixin DefineCollectorForStats!("faucet_stats", "collectStats");

    /***************************************************************************

        Constructor

        Params:
          config = Config instance

    ***************************************************************************/

    public this (Config config)
    {
        this.config = config;
        this.log = Logger(__MODULE__);

        // Create client for each address
        config.tx_generator.addresses.each!(address =>
            this.clients ~= Connection(address, new RestInterfaceClient!API(address)));
        mkdirRecurse(config.data.dir);
        auto stateDB = new ManagedDatabase(config.data.dir.buildPath("faucet.db"));
        auto params = makeConsensusParams(config.data.testing, config.consensus);
        this.ledger = new Ledger(params, stateDB,
            new BlockStorage(config.data.dir),
            new ValidatorSet(stateDB, params));
        Utils.getCollectorRegistry().addCollector(&this.collectStats);
    }

    /*******************************************************************************

        Take one of the clients selecting it randomly

        Returns:
          A client to send transactions or requests

    *******************************************************************************/

    private Connection randomClient () @trusted
    {
        return choice(this.clients);
    }

    ///
    private static Unlock keyUnlocker (in Transaction tx, in OutputRef out_ref) @safe nothrow
    {
        auto ownerSecret = secret_keys[out_ref.output.address];
        assert(ownerSecret !is SecretKey.init,
                "Address not known: " ~ out_ref.output.address.toString());

        return genKeyUnlock(KeyPair.fromSeed(ownerSecret).sign(tx.getChallenge()));
    }

    /*******************************************************************************

        Splits the Outputs from `utxo_rng` towards `count` random keys

        The keys are continuous in an associative array.
        We take `count` keys starting at a random position
        (no less than `count` before the end).

        Params:
          UR = Range of tuple with an `Output` (`value`) and
                 a `Hash` (`key`), as its first and second element, respectively
          count = The number of keys up to the number of available keys
            to spread the UTXOs to which will wrap around the keys if required

        Returns:
          A range of Transactions

    *******************************************************************************/

    private auto splitTx (UR) (UR utxo_rng, uint count)
    {
        static assert (isInputRange!UR);

        return utxo_rng
            .filter!(tup => tup.value.output.value >= minInputValuePerOutput * count)
            .map!((kv)
            {
                this.sent_utxos.put(kv.key);
                return TxBuilder(kv.value.output, kv.key);
            })
            .map!(txb => txb.unlockSigner(&this.keyUnlocker)
                .split(
                    secret_keys.byKey() // AA keys are addresses
                    .cycle()    // cycle the range of keys as needed
                    .drop(uniform(0, count, rndGen))    // start at some random position
                    .take(count))
                .sign());
    }

    /*******************************************************************************

        Merges the Outputs from `utxo_rng` into a range of transactions
        with a single input and output.

        Params:
          UR = Range of tuple with an `Output` (`value`) and
          a `Hash` (`key`), as its first and second element, respectively

        Returns:
          A range of Transactions

    *******************************************************************************/

    private Transaction mergeTx (UR) (UR utxo_rng) @safe
    {
        static assert (isInputRange!UR);

        // AA keys are addresses
        auto builder = TxBuilder(
            secret_keys.byKey().drop(uniform(0, secret_keys.length, rndGen)).front());
        builder.attach(utxo_rng);
        return builder.unlockSigner(&this.keyUnlocker).sign();
    }

    /*******************************************************************************

        Perform setup and make sure there is enough UTXOs for us to use

        Populate the ledger with the current state of node using `client`,
        and create transactions that will spread all spendable transactions from
        the last known block to `count` addresses.

        Params:
          client = An API instance to connect to a node
          count = The number of keys to spread the transactions to

    *******************************************************************************/

    public void setup (uint count)
    {
        while (!this.update(randomClient()))
            sleep(5.seconds);
        const utxo_len = this.owned_utxos.length;

        log.info("Setting up: height={}, {} UTXOs found", this.ledger.height(), utxo_len);
        if (utxo_len < 200)
        {
            assert(utxo_len >= 1);
            this.splitTx(this.owned_utxos.byKeyValue(), count)
                .take(8)
                .each!((tx)
                {
                    this.randomClient().postTransaction(tx);
                    this.faucet_stats.increaseMetricBy!"faucet_transactions_sent_total"(1);
                });
        }
    }

    /// Triggered every `block_interval` to ensure Faucet works even with
    /// its tx generator disabled
    private void update () @trusted
    {
        if (this.update(this.randomClient()))
        {
            // clear sent UTXOs on zero TX block
            if (this.ledger.lastBlock().txs.length == 0)
                this.sent_utxos.clear();
            log.trace("State has been updated: {}", this.ledger.height());
        }
    }

    /// Fetch blocks from a remote and add them to the Ledger
    private bool update (Connection client) @safe
    {
        Height remote;
        try
            remote = client.getBlockHeight();
        catch (Exception exc)
        {
            log.error("Client '{}' returned an error on getBlockHeight: {}",
                     client.address, () @trusted { return exc.message(); }() );
            return false;
        }

        log.trace("Peer {} is at height: {} (us: {})", client.address, remote, this.ledger.height);
        while (this.ledger.height() < remote)
        {
            const(Block)[] blocks;
            const Height from = this.ledger.height + 1;
            log.info("Requesting blocks [{} .. {}] from {}", from, remote, client.address);
            const max_blocks = cast(uint) (remote - from) + 1;
            try
                blocks = client.getBlocksFrom(from, max_blocks);
            catch (Exception exc)
            {
                log.error("Client '{}' returned an error on getBlocksFrom({}, {}): {}",
                          client.address, from, max_blocks,
                          () @trusted { return exc.message(); }());
                return false;
            }

            if (blocks.length)
                log.info("Received {} blocks: [{} .. {}]", blocks.length,
                         blocks[0].header.height, blocks[$ - 1].header.height);
            else
                log.warn("No blocks received from '{}'", client.address);

            const current_len = this.ledger.utxos.length;
            foreach (idx, ref b; blocks)
            {
                if (auto error = this.ledger.acceptBlock(b))
                {
                    log.error("Ledger refused externalization of block {}/{} (height: {}): {}",
                             idx, blocks.length, b.header.height, error);
                    log.error("Ledger height: {} - Faulty block: {}", this.ledger.height, b);
                    return false;
                }
            }

            // Use signed arithmetic to avoid negative values wrapping around
            const long delta = (cast(long) this.ledger.utxos.length) - current_len;
            log.info("UTXO delta: {}", delta);
        }

        this.owned_utxos = this.getOwnedUTXOs();
        assert(this.owned_utxos.length);
        return true;
    }

    /*******************************************************************************

        A task called periodically that generates and send transactions to a node

        This function will wait for block 1 to be externalized before doing anything
        (block 1 should be triggered by `setup`).
        Each time this runs, it creates 16 transactions which split an UTXO among
        15 random keys.

        Params:
          client = An API instance to connect to a node

    *******************************************************************************/

    void send ()
    {
        if (this.owned_utxos.length == 0)
            this.setup(this.config.tx_generator.split_count);

        log.info("About to send transactions...");

        // Sort them so we don't iterate multiple time
        // Note: This may cause a lot of memory usage, might need restructuing later
        // Mutable because of https://issues.dlang.org/show_bug.cgi?id=9792
        auto sutxo = this.owned_utxos.values.sort!((a, b) => a.output.value < b.output.value);
        const size = sutxo.length();
        const tsize = this.ledger.utxos.length();
        log.info("\tUTXO set: {}/{} UTXOs are owned by Faucet", size, tsize);

        if (sutxo.length)
        {
            immutable median = sutxo[size / 2].output.value;
            // Should be 500M (5,000,000,000,000,000) for the time being
            immutable sum = sutxo.map!(utxo => utxo.output.value).sum();
            auto mean = Amount(sum); mean.div(size);

            log.info("\tMedian: {}, Avg: {}", median, mean);
            log.info("\tL: {}, H: {}", sutxo[0].output.value, sutxo[$-1].output.value);
        }

        auto to_freeze_pks = validators.filter!((pk) {
            return this.ledger.utxos.getUTXOs(pk).byValue.all!(utxo => utxo.output.type != OutputType.Freeze) &&
                (pk !in this.freeze_txs || !this.randomClient().hasTransactionHash(this.freeze_txs[pk].hashFull));
        }).each!(pk => this.sendTo(pk.toString(), true));

        if (this.owned_utxos.length > this.config.tx_generator.merge_threshold)
        {
            foreach (_; 0..uniform(1, 10, rndGen))
            {
                auto utxo_rng = this.owned_utxos.byKeyValue()
                    .filter!(kv => kv.key !in this.sent_utxos)
                    .filter!(kv => kv.value.output.value >= minInputValuePerOutput)
                    .take(this.config.tx_generator.split_count);
                if (utxo_rng.empty)
                {
                    log.info("\tWaiting for unspent utxo");
                    break;
                }
                else
                {
                    auto tx = this.mergeTx(
                        utxo_rng.map!((kv)
                        {
                            this.sent_utxos.put(kv.key);
                            return tuple(kv.value.output, kv.key);
                        }));
                    log.info("\tMERGE: Sending a tx of byte size: {}", tx.sizeInBytes);
                    this.randomClient().postTransaction(tx);
                    log.dbg("Transaction sent (merge): {}", tx);
                    this.faucet_stats.increaseMetricBy!"faucet_transactions_sent_total"(1);
                }
            }
        }
        else
        {
            auto rng = this.splitTx(
                    this.owned_utxos.byKeyValue()
                        .filter!(kv => kv.key !in this.sent_utxos),
                    this.config.tx_generator.split_count)
                .take(uniform(1, 10, rndGen));
            if (rng.empty)
                log.info("\tSPLIT: Waiting for unspent utxo");
            else
            {
                log.info("\tSPLIT: Sending {} txs of total byte size: {}", rng.save.walkLength, rng.save.map!(t => t.sizeInBytes).sum);
                foreach (tx; rng)
                {
                    this.randomClient().postTransaction(tx);
                    log.dbg("Transaction sent (split): {}", tx);
                    this.faucet_stats.increaseMetricBy!"faucet_transactions_sent_total"(1);
                }
            }
        }
    }

    /// Get UTXOs owned by us that are spendable
    private UTXO[Hash] getOwnedUTXOs () @safe
    {
        UTXO[Hash] result;
        foreach (hash, utxo; this.ledger.utxos)
        {
            if (utxo.output.address !in secret_keys)
                continue;
            if (utxo.output.type != OutputType.Payment)
                continue;
            result[hash] = utxo;
        }
        return result;
    }

    /// GET: /utxos
    public override UTXO[Hash] getUTXOs (PublicKey key) @safe nothrow
    {
        return this.ledger.utxos.getUTXOs(key);
    }

    /// POST: /send
    public override void sendTransaction (string recv)
    {
        this.sendTo(recv, false);
    }

    /// POST: /stake
    public override void createValidatorStake (string recv)
    {
        this.sendTo(recv, true);
    }

    private void sendTo (string recv, bool freeze) @safe
    {
        PublicKey pubkey = PublicKey.fromString(recv);
        Amount amount = freeze ? 40_000.coins : 100.coins;
        Amount required = amount + (freeze ? 10_000.coins : 0.coins);
        auto owned_utxo_rng = this.owned_utxos.byKeyValue()
            // do not pick already used UTXOs
            .filter!(pair => pair.key !in this.used_utxos);

        auto owned_utxo_len = owned_utxo_rng.take(2).count;
        if (owned_utxo_len <= 1)
        {
            log.error("Insufficient UTXOs in storage. # of UTXOs: {}", owned_utxo_len);
            throw new Exception(format("Insufficient UTXOs in storage. # of UTXOs: %s", owned_utxo_len));
        }

        auto first_utxo = owned_utxo_rng.front;
        // add used UTXO to to used_utxos
        this.used_utxos[first_utxo.key] = first_utxo.value;
        owned_utxo_rng.popFront();
        assert(first_utxo.value.output.value > Amount(0));

        TxBuilder txb = TxBuilder(first_utxo.value.output, first_utxo.key);
        this.used_utxos[first_utxo.key] = first_utxo.value;
        Amount txb_value = first_utxo.value.output.value;

        while (txb_value < required)
        {
            auto new_utxo = owned_utxo_rng.front;
            this.used_utxos[new_utxo.key] = new_utxo.value;
            owned_utxo_rng.popFront();
            assert(new_utxo.value.output.value > Amount(0));
            txb.attach(new_utxo.value.output, new_utxo.key);
            txb_value += new_utxo.value.output.value;
        }

        Transaction tx = txb.unlockSigner(&this.keyUnlocker)
            .draw(amount, [pubkey])
            .sign(freeze ? OutputType.Freeze : OutputType.Payment);
        log.info("Sending {} BOA to {}", amount, recv);
        TransactionResult result = this.randomClient().postTransaction(tx);
        ensure(result.status == TransactionResult.Status.Accepted,
            "Transaction is {}: {}", result.status, result.reason);
        if (freeze)
            this.freeze_txs[pubkey] = tx;
        this.faucet_stats.increaseMetricBy!"faucet_transactions_sent_total"(1);
    }
}

/// Application entry point
int main (string[] args)
{
    CLIArgs clargs;
    bool verbose;

    auto helpInformation = () {
        auto r = clargs.parse(args);
        if (r.helpWanted) return r;
        return getopt(args,
            "v|verbose", &verbose);
    }();

    if (helpInformation.helpWanted)
    {
        defaultGetoptPrinter("Usage: ./faucet [-c <path>] - By default `config.yaml` is assumed",
            helpInformation.options);
        return 0;
    }

    // We need proper shut down or Faucet get stuck, see bosagora/faucet#72
    disableDefaultSignalHandlers();
    version (Posix)
    {
        import core.sys.posix.signal;

        sigset_t sigset;
        sigemptyset(&sigset);

        sigaction_t siginfo;
        siginfo.sa_handler = getSignalHandler();
        siginfo.sa_mask = sigset;
        siginfo.sa_flags = SA_RESTART;
        sigaction(SIGINT, &siginfo, null);
        sigaction(SIGTERM, &siginfo, null);
    }

    auto configN = parseConfigFileSimple!Config(clargs);
    if (configN.isNull())
        return 1;
    auto config = configN.get();

    foreach (const ref settings; config.logging)
    {
        if (settings.name.length == 0 || settings.name == "vibe")
            setVibeLogLevel(settings.level);
        configureLogger(settings, true);
    }

    config.tx_generator.keys.each!(kp => secret_keys.require(kp.address, kp.secret));
    validators = config.tx_generator.validator_public_keys;
    inst = new Faucet(config);

    inst.log.trace("{}", config);
    inst.log.info("We'll be sending transactions to the following clients: {}", config.tx_generator.addresses);
    inst.stats_server = new StatsServer(config.stats.address, config.stats.port);

    inst.updateTimer = setTimer(config.consensus.block_interval, &inst.update, true);
    inst.sendTx = setTimer(config.tx_generator.send_interval.seconds, () => inst.send(), true);
    if (config.web.address.length)
        inst.webInterface = startListeningInterface(config.web, inst);
    return runEventLoop();
}

private void restErrorHandler (
    HTTPServerRequest req, HTTPServerResponse res, RestErrorInformation info)
    @trusted
{
    // We don't use any info from the caller
    cast(void) req;

    static struct ErrorInfo
    {
        /// The error message itself
        const(char)[] statusMessage;
        debug
        {
            /// The stack trace
            const(char)[] statusDebugMessage;
        }
    }

    // If we are using a reusable exception, then we might need to save the
    // error message in a buffer to avoid it being rewritten during a context
    // switch to another fiber.
    // `agora.common.Ensure : FormattedException` uses a 2kb buffer but we
    // limit ourselves to much less in order to not consume half a page for this
    char[512] buffer;
    scope const msg = info.exception.message();
    scope slice = buffer[0 .. msg.length > $ ? $ : msg.length];
    slice[] = msg[];

    // Send the full stack trace in debug mode (allocates quite a bit)
    // We also always assume user error instead of internal server error
    debug res.writeJsonBody(ErrorInfo(slice, info.exception.toString()), HTTPStatus.badRequest);
    else  res.writeJsonBody(ErrorInfo(slice), HTTPStatus.badRequest);
}

private HTTPListener startListeningInterface (in ListenerConfig web, Faucet faucet)
{
    auto settings = new HTTPServerSettings(web.address);
    settings.port = web.port;
    auto router = new URLRouter();
    auto rest_settings = new RestInterfaceSettings;
    rest_settings.errorHandler = toDelegate(&restErrorHandler);
    router.registerRestInterface(faucet, rest_settings);

    string path = getStaticFilePath();
    /// Convenience redirect, as users expect that accessing '/' redirect to index.html
    router.match(HTTPMethod.GET, "/", staticRedirect("/index.html", HTTPStatus.movedPermanently));
    /// By default, match the underlying files
    router.match(HTTPMethod.GET, "*", serveStaticFiles(path));

    inst.log.info("About to listen to HTTP: {}:{}", web.address, web.port.value);
    return listenHTTP(settings, router);
}

/// Returns: The path at which the files are located
private string getStaticFilePath ()
{
    if (std.file.exists("frontend/index.html"))
        return std.file.getcwd() ~ "/frontend/";

    if (std.file.exists("/usr/share/faucet/frontend/index.html"))
        return "/usr/share/faucet/frontend/";

    throw new Exception("Files not found. " ~
                        "This might mean your faucet is not installed correctly. " ~
                        "Searched for `index.html` in '" ~ std.file.getcwd() ~
                        "/frontend/'.");
}

/// Global because we need to access it from our signal handler
private Faucet inst;

/// Type of the handler that is called when a signal is received
private alias SigHandlerT = extern(C) void function (int sig) nothrow;

/// Returns a signal handler
/// This routine is there solely to ensure the function has a mangled name,
/// and doesn't accidentally conflict with other code.
private SigHandlerT getSignalHandler () @safe pure nothrow @nogc
{
    extern(C) void signalHandler (int signal) nothrow
    {
        // Calling `printf` because `writeln` is not `@nogc`
        printf("Received signal %d, shutting down listeners...\n", signal);
        try
        {
            inst.webInterface.stopListening();
            inst.webInterface = typeof(inst.webInterface).init;
            inst.stats_server.shutdown();
            inst.updateTimer.stop();
            inst.updateTimer = Timer.init;
            inst.sendTx.stop();
            inst.sendTx = inst.sendTx.init;
            printf("Terminating event loop...\n");
            exitEventLoop();
        }
        catch (Throwable exc)
        {
            printf("Exception thrown while shutting down: %.*s\n",
                   cast(int) exc.msg.length, exc.msg.ptr);
            debug {
                scope (failure) assert(0);
                writeln("========================================");
                writeln("Full stack trace: ", exc);
            }
        }
    }

    return &signalHandler;
}

/// Make a new instance of the consensus parameters based on the config
/// Adapted from `FullNode.makeConsensusConfig`
public static makeConsensusParams (bool testing, in ConsensusConfig config)
{
    import TESTNET = agora.consensus.data.genesis.Test;
    import COINNET = agora.consensus.data.genesis.Coinnet;

    return new immutable(ConsensusParams)(
        testing ? TESTNET.GenesisBlock : COINNET.GenesisBlock,
        testing ? TESTNET.CommonsBudgetAddress : COINNET.CommonsBudgetAddress,
        config);
}
