import "@acton/io"

import "@wrappers/AgenticCollection.gen"
import "@wrappers/AgenticWallet.gen"

import "@scripts/utils/collection"
import "@scripts/utils/common"
import "@scripts/utils/wallet"

fun main() {
    printNetwork();
    val admin = promptSigner("AGENTIC_ADMIN_SIGNER", "Select admin signer");
    val collection = promptAgenticCollection();
    val walletIndex = promptAgenticInt("AGENTIC_WALLET_INDEX", "Enter wallet index", "0");
    val value = promptMessageValue();
    val wallet = AgenticWallet.fromAddress(collection.getNftAddressByIndex(walletIndex));
    val currentContent = wallet.getNftData().content;
    println("AGENTIC_WALLET={}", wallet.address);
    println("AGENTIC_WALLET_CONTENT={}", currentContent);
    val content = promptWalletContent(currentContent);
    confirmSend();

    collection
        .sendRelayEditWalletContent(
            admin.address,
            newQueryId(),
            walletIndex,
            content,
            { value, bounce: true },
        )
        .confirm();

    printAgenticWalletInfo(wallet);
}
