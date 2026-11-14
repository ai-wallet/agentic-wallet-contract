import "@acton/io"

import "@wrappers/send"

import "@scripts/utils/common"
import "@scripts/utils/wallet"

fun main() {
    printNetwork();
    val owner = promptSigner("AGENTIC_OWNER_SIGNER", "Select owner signer");
    val wallet = promptAgenticWallet();
    val value = promptMessageValue();
    val (recipient, action) = promptTransfer();
    println("AGENTIC_WALLET={}", wallet.address);
    confirmSend();

    val trace = wallet
        .sendOwnerActions(
            owner.address,
            newQueryId(),
            [action],
            { value, bounce: true },
        )
        .confirm();
    assertReached(trace, recipient);

    printAgenticWalletInfo(wallet);
}
