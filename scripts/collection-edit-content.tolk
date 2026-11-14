import "@acton/io"
import "@acton/prompts"
import "@acton/emulation/network"

import "@contracts/storage"
import "@wrappers/AgenticCollection.gen"

import "@wrappers/utils"

import "@scripts/utils/collection"
import "@scripts/utils/common"

/// Replaces the collection content and the royalty params in one message. The current values are
/// the defaults.
fun main() {
    printNetwork();
    val admin = promptSigner("AGENTIC_ADMIN_SIGNER", "Select admin signer");
    val collection = promptAgenticCollection();
    val storage = fetchCollectionStorage(collection.address);
    var content = storage.content.load();
    var royalty = storage.royaltyParams.load();

    if (
        confirm(
            "Replace collection metadata?",
            envBool("AGENTIC_REPLACE_METADATA") ?? false,
            "no keeps the current metadata",
        )
    ) {
        content.collectionMetadata = buildOnchainMetadata(
            promptAgenticCollectionInfo(content.collectionMetadata),
        );
    }
    content.commonContent = promptCommonContent(content.commonContent);
    if (
        confirm(
            "Replace royalty params?",
            envBool("AGENTIC_REPLACE_ROYALTY") ?? false,
            "no keeps the current royalty params",
        )
    ) {
        royalty = promptRoyaltyParams(royalty);
    }
    val value = promptMessageValue();
    println("AGENTIC_COLLECTION={}", collection.address);
    confirmSend();

    collection
        .sendEditCollectionContent(
            admin.address,
            newQueryId(),
            content,
            royalty,
            { value, bounce: true },
        )
        .confirm();

    printAgenticCollectionInfo(collection);
}
