import "@acton/io"

import "@wrappers/AgenticCollection.gen"

import "@scripts/utils/collection"
import "@scripts/utils/common"

fun main() {
    printNetwork();
    val admin = promptSigner("AGENTIC_ADMIN_SIGNER", "Select current admin signer");
    val collection = promptAgenticCollection();
    val newAdmin = promptAgenticAddress("AGENTIC_NEW_ADMIN", "Enter new admin address");
    assertNotLockedAddress("AGENTIC_NEW_ADMIN", newAdmin, collection.address);
    val value = promptMessageValue();
    println("AGENTIC_COLLECTION={}", collection.address);
    println("AGENTIC_NEW_ADMIN={}", newAdmin);
    confirmSend();

    collection
        .sendChangeCollectionAdmin(admin.address, newQueryId(), newAdmin, { value, bounce: true })
        .confirm();

    printAgenticCollectionInfo(collection);
}
