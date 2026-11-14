import "@acton/io"
import "@acton/testing/assert"

import "@contracts/fees"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/send"
import "@wrappers/utils"

import "@scripts/utils/common"
import "@scripts/utils/wallet"

fun main() {
    printNetwork();
    val owner = promptSigner("AGENTIC_OWNER_SIGNER", "Select owner signer");
    val wallet = promptAgenticWallet();
    val newOwner = promptAgenticAddress("AGENTIC_NEW_OWNER", "Enter new owner address");
    assertNotLockedAddress(
        "AGENTIC_NEW_OWNER",
        newOwner,
        wallet.address,
        wallet.getNftData().collectionAddress,
    );
    val sendExcessesTo = promptAgenticAddress(
        "AGENTIC_EXCESSES_TO",
        "Enter address for the excess",
        owner.address,
    );
    val forwardAmount = promptGrams(
        "AGENTIC_FORWARD_AMOUNT",
        "Enter new owner notification amount",
        MIN_FORWARD_AMOUNT,
    );
    val forwardPayload = promptForwardPayload();
    // the wallet pays the notification from this value, so the default adds it
    val value = promptMessageValue(
        DEFAULT_MESSAGE_VALUE + forwardAmount,
        "Enter message value (must pay the new owner notification)",
    );
    // a value that is not more than the forward amount always bounces with TooSmallFunding (807).
    // The value must also pay up to two forward fees, which grow with the comment length. The
    // default covers short comments.
    if (value <= forwardAmount) {
        Assert.fail("Message value must be more than the new owner notification amount");
    }
    println("AGENTIC_WALLET={}", wallet.address);
    println("AGENTIC_NEW_OWNER={}", newOwner);
    confirmSend();

    wallet
        .sendChangeWalletOwnerPayloadAuto(
            owner.address,
            newQueryId(),
            newOwner,
            sendExcessesTo,
            null,
            forwardAmount,
            forwardPayload,
            { value, bounce: true },
        )
        .confirm();

    printAgenticWalletInfo(wallet);
}
