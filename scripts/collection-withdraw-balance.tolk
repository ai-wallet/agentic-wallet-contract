import "@acton/io"

import "@wrappers/AgenticCollection.gen"

import "@scripts/utils/collection"
import "@scripts/utils/common"

/// The collection keeps its storage reserve and sends the rest of its balance to the admin.
fun main() {
    printNetwork();
    val admin = promptSigner("AGENTIC_ADMIN_SIGNER", "Select admin signer");
    val collection = promptAgenticCollection();
    val value = promptMessageValue();
    println("AGENTIC_COLLECTION={}", collection.address);
    confirmSend();

    collection
        .sendWithdrawCollectionBalance(admin.address, newQueryId(), { value, bounce: true })
        .confirm();

    printAgenticCollectionInfo(collection);
}
