import "@acton/io"

import "@wrappers/AgenticWallet.gen"

import "@scripts/utils/common"
import "@scripts/utils/wallet"

fun main() {
    printNetwork();
    val owner = promptSigner("AGENTIC_OWNER_SIGNER", "Select owner signer");
    val wallet = promptAgenticWallet();
    val delegatePublicKey = promptDelegatePublicKey();
    val value = promptMessageValue();
    println("AGENTIC_WALLET={}", wallet.address);
    println("AGENTIC_DELEGATE_PUBLIC_KEY={}", formatPublicKey(delegatePublicKey));
    confirmSend();

    wallet
        .sendChangeWalletDelegate(
            owner.address,
            newQueryId(),
            delegatePublicKey,
            { value, bounce: true },
        )
        .confirm();

    printAgenticWalletInfo(wallet);
}
