import "@stdlib/strings"

import "@acton/crypto"
import "@acton/fmt"
import "@acton/io"
import "@acton/prompts"
import "@acton/emulation/scripts"
import "@acton/testing/assert"

import "@contracts/wallet-content"

import "@wrappers/AgenticWallet.gen"
import "@wrappers/utils"

import "@scripts/utils/common"

// Constants

/// Lifetime of a signed request. It must include the time for the prompts.
const VALID_FOR_SECONDS = 300

// Wallet address

fun promptAgenticWallet(): AgenticWallet {
    return AgenticWallet.fromAddress(
        promptAgenticAddress("AGENTIC_WALLET", "Enter agentic wallet address"),
    );
}

// Wallet content

/// Prompts for one of the 3 wallet content formats that `get_nft_content` supports:
/// index: "<prefix><walletIndex>.json", trait-set: "<prefix><traitSetIndex>/<walletIndex>.json",
/// url: the URL as entered. The current content (on edit) prefills the prompts.
fun promptWalletContent(current: cell?): cell {
    var mode = "index";
    var traitSet = "0";
    var url = "";
    if (current != null) {
        val parsed = lazy PrefillContent.fromSlice(current.beginParse());
        match (parsed) {
            TraitSetContent => {
                mode = "trait-set";
                traitSet = parsed.traitSetIndex.toDecimalString();
            }
            UrlContent => {
                mode = "url";
                url = parsed.url;
            }
            else => {}
        }
    }
    mode = promptAgenticString(
        "AGENTIC_WALLET_CONTENT_MODE",
        "Enter wallet content mode: index, trait-set or url",
        mode,
    );
    if (mode.equalTo("index")) {
        return WalletIndexContent {}.toCell();
    }
    if (mode.equalTo("trait-set")) {
        val traitSetIndex = promptAgenticInt(
            "AGENTIC_WALLET_TRAIT_SET",
            "Enter trait set index (without .json)",
            traitSet,
        );
        return TraitSetContent { traitSetIndex }.toCell();
    }
    if (!mode.equalTo("url")) {
        Assert.fail("Wallet content mode must be index, trait-set or url");
    }
    return walletContent(
        promptAgenticString("AGENTIC_WALLET_URL", "Enter full wallet content URL", url),
    );
}

// Transfers and payloads

/// Prompts for a transfer from the wallet balance and prints it. Returns the recipient and the
/// send action.
fun promptTransfer(): (address, SendMessageAction) {
    val recipient = promptAgenticAddress("AGENTIC_RECIPIENT", "Enter recipient address");
    val amount = promptGrams(
        "AGENTIC_TRANSFER_AMOUNT",
        "Enter transfer amount",
        DEFAULT_TRANSFER_AMOUNT,
    );
    val comment = promptAgenticString("AGENTIC_COMMENT", "Enter comment (empty: none)", "");
    println("AGENTIC_RECIPIENT={}", recipient);
    println("AGENTIC_TRANSFER_AMOUNT={}", formatGramsInput(amount));
    return (recipient, sendMessageAction(recipient, amount, commentBody(comment)));
}

/// TEP-62 forward payload: a text comment, or empty.
fun promptForwardPayload(): slice {
    val body = commentBody(
        promptAgenticString("AGENTIC_FORWARD_COMMENT", "Enter forward comment (empty: none)", ""),
    );
    return body == null ? createEmptySlice() : body.beginParse();
}

// Delegate key and signed requests

/// Delegate key pair from `AGENTIC_DELEGATE_PRIVATE_KEY` (the 32-byte Ed25519 seed). The script
/// does not prompt for it, because Acton has no masked prompt. The script never shows it.
fun delegateKeyPair(): KeyPair {
    val fromEnv = envNonEmpty("AGENTIC_DELEGATE_PRIVATE_KEY");
    if (fromEnv == null) {
        Assert.fail("AGENTIC_DELEGATE_PRIVATE_KEY required. See README.md, section Scripts");
    }
    val seed = parseIntInput(fromEnv, "AGENTIC_DELEGATE_PRIVATE_KEY");
    return seedKeyPair(seed, "AGENTIC_DELEGATE_PRIVATE_KEY");
}

/// Key pair from a 32-byte seed. Rejects a negative seed: it signs with a different key, and no
/// later step serializes the seed to find the error. A non-negative TVM integer always fits.
fun seedKeyPair(seed: int, what: string): KeyPair {
    if (seed < 0) {
        Assert.fail(format("{} must be a 32-byte key", what));
    }
    return crypto.seedToKeyPair(seed);
}

/// Prompts for the delegate public key. Prefill: `AGENTIC_DELEGATE_PUBLIC_KEY` if set, else
/// the public key of `AGENTIC_DELEGATE_PRIVATE_KEY`, else 0. Enter 0 to remove the delegate.
fun promptDelegatePublicKey(): uint256 {
    val hasSeed = envNonEmpty("AGENTIC_DELEGATE_PRIVATE_KEY") != null;
    return promptAgenticInt(
        "AGENTIC_DELEGATE_PUBLIC_KEY",
        "Enter delegate public key, 0x... (0: no delegate)",
        hasSeed ? formatPublicKey(delegateKeyPair().publicKey) : "0",
    );
}

/// Fails if `wallet` rejects requests signed with `publicKey`. The wallet drops a rejected
/// external without a transaction, so a send gives only a trace timeout. It ignores a rejected
/// internal and keeps its value.
fun assertDelegateKeyMatches(wallet: AgenticWallet, publicKey: uint256) {
    // the getter fails with a raw error on an address without a contract
    if (!scripts.isContractDeployed(wallet.address)) {
        Assert.fail("No contract at the agentic wallet address");
    }
    val walletKey = wallet.getPublicKey();
    if (walletKey == 0) {
        Assert.fail("The wallet has no delegate key or is not initialized: it rejects signed requests");
    }
    if (walletKey != publicKey) {
        Assert.fail(
            format(
                "Delegate key {} does not match the wallet delegate key {}",
                formatPublicKey(publicKey),
                formatPublicKey(walletKey),
            ),
        );
    }
}

/// Asks how to send a signed request. `AGENTIC_SIGNED_VIA=internal` preselects internal.
fun signedViaInternal(): bool {
    val fromEnv = envNonEmpty("AGENTIC_SIGNED_VIA");
    var defaultIndex = 0;
    if (fromEnv != null) {
        if (fromEnv.equalTo("internal")) {
            defaultIndex = 1;
        } else if (!fromEnv.equalTo("external")) {
            Assert.fail("AGENTIC_SIGNED_VIA must be external or internal");
        }
    }
    return select(
        "Send signed request via",
        ["external", "internal"],
        defaultIndex,
    ).equalTo("internal");
}

// Info

fun printAgenticWalletInfo(wallet: AgenticWallet) {
    val data = wallet.getNftData();
    println("AGENTIC_WALLET={}", wallet.address);
    println("AGENTIC_INITIALIZED={}", data.isInitialized);
    println("AGENTIC_WALLET_INDEX={}", data.walletIndex);
    println("AGENTIC_COLLECTION={}", data.collectionAddress);
    println("AGENTIC_WALLET_OWNER={}", data.ownerAddress);
    println("AGENTIC_CONTENT={}", data.content);
    println("AGENTIC_SEQNO={}", wallet.seqno());
    println("AGENTIC_DELEGATE_PUBLIC_KEY={}", formatPublicKey(wallet.getPublicKey()));
    // the wallet pays the gas of signed externals from this balance
    println("AGENTIC_BALANCE={:gram}", scripts.fetchAccountBalance(wallet.address));
}
