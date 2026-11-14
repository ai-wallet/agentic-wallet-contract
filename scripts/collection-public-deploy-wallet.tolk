import "@acton/io"

import "@wrappers/AgenticCollection.gen"

import "@wrappers/utils"

import "@scripts/utils/collection"
import "@scripts/utils/common"
import "@scripts/utils/wallet"

fun main() {
    printNetwork();
    val requester = promptSigner("AGENTIC_REQUESTER_SIGNER", "Select requester signer");
    val collection = promptAgenticCollection();
    val settings = collection.getCollectionSettings();
    val referralAddress = promptAgenticOptionalAddress(
        "AGENTIC_REFERRAL_ADDRESS",
        "Enter referral address (empty: none)",
    );
    val leftover = promptGrams(
        "AGENTIC_WALLET_LEFTOVER",
        "Enter value for the wallet (sent in addition to the deploy price)",
        DEFAULT_WALLET_LEFTOVER,
    );
    val reward: coins = referralAddress == null
        ? 0
        : referralReward(settings.deployPrice, settings.referralBps);
    val value = settings.deployPrice + leftover;
    println("AGENTIC_COLLECTION={}", collection.address);
    println("AGENTIC_NEXT_WALLET_INDEX={}", collection.getCollectionData().nextWalletIndex);
    println("AGENTIC_WALLET_OWNER={}", requester.address);
    println("AGENTIC_DEPLOY_PRICE={}", formatGramsInput(settings.deployPrice));
    println("AGENTIC_REFERRAL_REWARD={:gram}", reward);
    println("AGENTIC_PUBLIC_DEPLOY_VALUE={:gram}", value);
    confirmSend();

    val wallet = publicDeployAgenticWallet(collection, requester, referralAddress, value);

    printAgenticWalletInfo(wallet);
}
