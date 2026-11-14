import "@stdlib/strings"

import "@acton/env"
import "@acton/ffi"
import "@acton/fmt"
import "@acton/io"
import "@acton/prompts"
import "@acton/emulation/config"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/testing/assert"
import "@acton/types/big_array"
import "@acton/types/message"
import "@acton/types/transaction"

import "@wrappers/utils"

// Constants

const MAINNET_GLOBAL_ID = -239
// the indexer of a public network can take some time to index a trace
const TRACE_WAIT_ATTEMPTS = 15
const TRACE_WAIT_SLEEP_MS = 2000

// Env values

/// Env value. An empty value is the same as unset.
fun envNonEmpty(name: string): string? {
    val value = env<string>(name);
    if (value != null && value.calculateLength() != 0) {
        return value;
    }
    return null;
}

/// Boolean env value: true/1 (any case) or false/False/FALSE/0. Empty means unset. Any other
/// value fails, so it does not silently mean false.
fun envBool(name: string): bool? {
    val raw = envNonEmpty(name);
    if (raw == null) {
        return null;
    }
    if (env<bool>(name) ?? false) {
        return true;
    }
    if (raw.equalTo("0") || raw.equalTo("false") || raw.equalTo("False") || raw.equalTo("FALSE")) {
        return false;
    }
    Assert.fail(format("{} must be true or false", name));
}

/// Address env value. Accepts printed `<address> (<name>)` lines. Fails if a set value is invalid.
fun envAddress(name: string): address? {
    val raw = envNonEmpty(name);
    if (raw == null) {
        return null;
    }
    try {
        return parseAddress(raw);
    } catch {
        Assert.fail(format("{} must be a TON address", name));
    }
}

// Parse and format

/// Integer from free-text input. Fails with a clear message instead of a bare exit 5.
fun parseIntInput(input: string, what: string): int {
    val value = ffi.parseInt(input);
    if (value != null) {
        return value;
    }
    Assert.fail(format("{} must be an integer", what));
}

/// Parses a GRAM amount like "0.05" or "1" into nanograms (up to 9 decimals).
fun parseGrams(amount: string, what: string): coins {
    var s = amount.beginParse();
    var nano = 0;
    var decimals = -1;
    var digits = 0;
    while (s.remainingBitsCount() >= 8) {
        val c = s.loadUint(8);
        if (c == 0x2E && decimals < 0) {
            decimals = 0;
        } else if (c >= 0x30 && c <= 0x39 && decimals < 9) {
            nano = nano * 10 + (c - 0x30);
            digits += 1;
            if (decimals >= 0) {
                decimals += 1;
            }
        } else {
            Assert.fail(format("{} must be a GRAM amount", what));
        }
    }
    if (digits == 0) {
        Assert.fail(format("{} must be a GRAM amount", what));
    }
    repeat (9 - (decimals < 0 ? 0 : decimals)) {
        nano *= 10;
    }
    return nano;
}

/// GRAM amount without a unit, for example "0.05", for prompts and output to paste. `{:gram}`
/// adds a unit.
fun formatGramsInput(nano: coins): string {
    var fraction = nano % 1000000000;
    if (fraction == 0) {
        return format("{}", nano / 1000000000);
    }
    var width = 9;
    while (fraction % 10 == 0) {
        fraction /= 10;
        width -= 1;
    }
    var digits = format("{}", fraction);
    repeat (width - digits.calculateLength()) {
        digits = format("0{}", digits);
    }
    return format("{}.{}", nano / 1000000000, digits);
}

/// Ed25519 public key as 0x and 64 hex digits, as the scripts print and read it.
fun formatPublicKey(key: uint256): string {
    return format("0x{:064x}", key);
}

// Prompts

/// A signer: an Acton wallet from the Acton wallet picker, or the connected wallet with
/// `--tonconnect`. The script first offers the signer that `envName` names.
fun promptSigner(envName: string, message: string): ActonWallet {
    val fromEnv = envNonEmpty(envName);
    if (fromEnv != null) {
        val useEnv = confirm(format("Use signer \"{}\"?", fromEnv), true, envName);
        if (useEnv) {
            return scripts.wallet(fromEnv);
        }
    }
    return scripts.wallet(promptWallet(message));
}

// other env values prefill or preselect prompts, so the user sees an old value before its use

fun promptAgenticAddress(envName: string, message: string, default: address? = null): address {
    return promptAddress(message, envAddress(envName) ?? default);
}

/// An address that the user can leave empty (null).
fun promptAgenticOptionalAddress(envName: string, message: string): address? {
    envAddress(envName);
    val input = promptAgenticString(envName, message, "");
    return input.calculateLength() == 0 ? null : parseAddress(input);
}

fun promptAgenticString(envName: string, message: string, default: string): string {
    return prompt(message, "", envNonEmpty(envName) ?? default);
}

/// Integer prompt, prefilled from `envName` or `default`. A malformed env value fails with a
/// clear message, even when the prompt can not ask again (non-interactive runs).
fun promptAgenticInt(envName: string, message: string, default: string): int {
    val prefill = envNonEmpty(envName) ?? default;
    parseIntInput(prefill, envName);
    // the original text keeps a hex default easy to read. promptInt parses it in the same way.
    return promptInt(message, prefill);
}

fun promptGrams(envName: string, message: string, default: coins): coins {
    val prefill = envNonEmpty(envName) ?? formatGramsInput(default);
    return parseGrams(prompt(message, "in GRAM", prefill), envName);
}

/// Prompts for the value of the message to the contract. `AGENTIC_MESSAGE_VALUE` prefills it.
fun promptMessageValue(
    default: coins = DEFAULT_MESSAGE_VALUE,
    message: string = "Enter message value",
): coins {
    return promptGrams("AGENTIC_MESSAGE_VALUE", message, default);
}

/// Text prompt for an optional field. "-" gives an empty value; an empty input keeps `default`.
fun promptOptionalText(envName: string, message: string, default: string): string {
    val input = promptAgenticString(envName, message, default);
    return input.equalTo("-") ? "" : input;
}

/// Stops the script if `value` is `locked` or `alsoLocked`. These addresses are not supported in
/// the role: the collection can not act in it, and a self-owned wallet needs a delegate key.
fun assertNotLockedAddress(
    name: string,
    value: address,
    locked: address,
    alsoLocked: address? = null,
) {
    if (value == locked || (alsoLocked != null && value == alsoLocked)) {
        Assert.fail(
            format("{} must not be {}: this address is not supported in this role", name, value),
        );
    }
}

// Network and send confirmation

/// Global ID (config param 19) of the target network. GLOBALID reads the config of the local
/// executor. On custom networks, such as a simulator, this config is different from the target.
fun targetGlobalId(): int {
    return scripts.fetchConfig().getParamRaw(19).beginParse().loadInt(32);
}

/// Name of the target network: EMULATION without `--net`, MAINNET for the mainnet global ID,
/// else NON-MAINNET. Acton does not give the --net name, and a simulator forked from testnet
/// has the testnet global ID.
fun networkName(): string {
    if (!net.isBroadcasting()) {
        return "EMULATION";
    }
    return targetGlobalId() == MAINNET_GLOBAL_ID ? "MAINNET" : "NON-MAINNET";
}

fun printNetwork() {
    println("NETWORK={} GLOBAL_ID={}", networkName(), targetGlobalId());
}

/// Asks for confirmation before a broadcast. On mainnet, the suggested answer is no.
/// `AGENTIC_CONFIRM_SEND` prefills the answer. Emulation sends nothing, so it does not ask.
fun confirmSend() {
    if (!net.isBroadcasting()) {
        return;
    }
    val network = networkName();
    val confirmed = confirm(
        format("Send to {}?", network),
        envBool("AGENTIC_CONFIRM_SEND") ?? !network.equalTo("MAINNET"),
        "sends real transactions",
    );
    if (!confirmed) {
        Assert.fail("Send not confirmed");
    }
}

/// Query ID of a script request: the unix time. It lets you match replies and excesses to it.
fun newQueryId(): uint64 {
    return blockchain.now();
}

// Trace checks

fun inMsg(result: SendResult): TlbMessage<RemainingBitsAndRefs> {
    return result.tx.load().loadInMsg<RemainingBitsAndRefs>();
}

fun inMsgInfo(result: SendResult): TlbCommonMessageInfo {
    return inMsg(result).info;
}

/// Reason why `trace` failed, or null if all transactions succeeded. A skipped compute phase
/// without a bounce is not a failure, for example a non-bounceable transfer to an undeployed
/// account.
fun traceFailure(trace: SendResultList): string? {
    var i = 0;
    while (i < trace.size()) {
        val description = trace.get(i).tx.load().description.load();
        if (description is TlbTransOrd && description.aborted) {
            val compute = description.computePh;
            if (compute is TlbTrComputeVm) {
                return compute.success
                    ? "A transaction failed in its action phase"
                    : format(
                        "A transaction failed with exit code {}",
                        compute.data.load().exitCode,
                    );
            }
        }
        val info = inMsgInfo(trace.get(i));
        if (info is TlbInternalMessage && info.bounced) {
            return "A message bounced (is the target deployed and the sender allowed?)";
        }
        i += 1;
    }
    return null;
}

/// Prints the trace. Fails if the trace did not settle or a transaction in it failed.
fun assertTraceSucceeded(trace: SendResultList?): SendResultList {
    if (trace == null) {
        // the transaction can still land, and a resend without a check can deploy a second
        // wallet. An external that the contract rejects never lands.
        Assert.fail("Not confirmed: no settled trace in time; check state before retrying");
    }
    println(trace);
    val failure = traceFailure(trace);
    if (failure != null) {
        Assert.fail(failure);
    }
    return trace;
}

/// Waits for the full trace. Fails if a transaction in it failed.
fun SendResultList.confirm(self): SendResultList {
    return assertTraceSucceeded(self.waitForTrace(false, TRACE_WAIT_ATTEMPTS, TRACE_WAIT_SLEEP_MS));
}

fun ExternalSendResult.confirm(self): SendResultList {
    return assertTraceSucceeded(self.waitForTrace(false, TRACE_WAIT_ATTEMPTS, TRACE_WAIT_SLEEP_MS));
}

/// Fails if `trace` has no transaction at `recipient`. The wallet skips a request from a wrong
/// owner or key without a failure. It also skips a send that it can not pay for (mode +2).
fun assertReached(trace: SendResultList, recipient: address) {
    var i = 0;
    while (i < trace.size()) {
        val info = inMsgInfo(trace.get(i));
        if (info is TlbInternalMessage && info.dest == recipient) {
            return;
        }
        i += 1;
    }
    Assert.fail("No transfer reached the recipient (wrong owner/key or low wallet balance)");
}
