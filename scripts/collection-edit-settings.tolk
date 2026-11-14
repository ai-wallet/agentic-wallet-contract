import "@acton/io"

import "@wrappers/AgenticCollection.gen"

import "@scripts/utils/collection"
import "@scripts/utils/common"

fun main() {
    printNetwork();
    val admin = promptSigner("AGENTIC_ADMIN_SIGNER", "Select admin signer");
    val collection = promptAgenticCollection();
    val settings = promptCollectionSettings(collection.getCollectionSettings());
    val value = promptMessageValue();
    println("AGENTIC_COLLECTION={}", collection.address);
    println("AGENTIC_MAX_WALLET_INDEX={}", settings.maxWalletIndex);
    println("AGENTIC_PUBLIC_DEPLOY_ENABLED={}", settings.publicDeployEnabled);
    println("AGENTIC_DEPLOY_PRICE={}", formatGramsInput(settings.deployPrice));
    println("AGENTIC_REFERRAL_BPS={}", settings.referralBps);
    println("AGENTIC_TRAIT_SET_COUNT={}", settings.traitSetCount);
    confirmSend();

    collection
        .sendEditCollectionSettings(
            admin.address,
            newQueryId(),
            settings.maxWalletIndex,
            settings.publicDeployEnabled,
            settings.deployPrice,
            settings.referralBps,
            settings.traitSetCount,
            { value, bounce: true },
        )
        .confirm();

    printAgenticCollectionInfo(collection);
}
