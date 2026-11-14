import "@acton/io"

import "@contracts/storage"
import "@wrappers/utils"

import "@scripts/utils/collection"
import "@scripts/utils/common"

fun main() {
    printNetwork();
    val admin = promptSigner("AGENTIC_ADMIN_SIGNER", "Select admin signer");
    val info = promptAgenticCollectionInfo();
    val commonContent = promptCommonContent(DEFAULT_COMMON_CONTENT);
    val royalty = promptRoyaltyParams({
        numerator: 5,
        denominator: 100,
        royaltyAddress: admin.address,
    });
    val settings = promptCollectionSettings({
        maxWalletIndex: MAX_WALLET_INDEX_UNLIMITED,
        publicDeployEnabled: false,
        deployPrice: DEFAULT_DEPLOY_PRICE,
        referralBps: 0,
        traitSetCount: DEFAULT_TRAIT_SET_COUNT,
    });
    val value = promptGrams("AGENTIC_DEPLOY_VALUE", "Enter deploy value", DEFAULT_DEPLOY_VALUE);
    println("AGENTIC_ADMIN={}", admin.address);
    confirmSend();

    val collection = deployAgenticCollection(
        admin,
        makeAgenticCollectionStorage(admin.address, info, commonContent, royalty, settings),
        value,
    );

    printAgenticCollectionInfo(collection);
}
