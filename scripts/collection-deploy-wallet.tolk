import "@acton/io"

import "@contracts/fees"
import "@contracts/messages"
import "@wrappers/AgenticCollection.gen"
import "@wrappers/utils"

import "@scripts/utils/collection"
import "@scripts/utils/common"
import "@scripts/utils/wallet"

fun main() {
    printNetwork();
    val admin = promptSigner("AGENTIC_ADMIN_SIGNER", "Select admin signer");
    val collection = promptAgenticCollection();
    val walletIndex = promptWalletIndex();
    val owner = promptAgenticAddress(
        "AGENTIC_WALLET_OWNER",
        "Enter wallet owner address",
        admin.address,
    );
    val targetIndex = walletIndex ?? collection.getCollectionData().nextWalletIndex;
    assertNotLockedAddress(
        "AGENTIC_WALLET_OWNER",
        owner,
        collection.address,
        collection.getNftAddressByIndex(targetIndex),
    );
    val content = promptWalletContent(null);
    val delegatePublicKey = promptDelegatePublicKey();
    val forwardAmount = promptGrams(
        "AGENTIC_FORWARD_AMOUNT",
        "Enter owner notification amount",
        MIN_FORWARD_AMOUNT,
    );
    val forwardPayload = promptForwardPayload();
    // the wallet pays the notification in addition to its storage reserve, so the defaults add it
    val attachAmount = promptGrams(
        "AGENTIC_WALLET_ATTACH_AMOUNT",
        "Enter value sent to the wallet (must pay its storage reserve and the owner notification)",
        DEFAULT_WALLET_ATTACH_AMOUNT + forwardAmount,
    );
    val value = promptMessageValue(DEFAULT_DEPLOY_MESSAGE_VALUE + forwardAmount);
    println("AGENTIC_COLLECTION={}", collection.address);
    if (walletIndex != null) {
        println("AGENTIC_WALLET_INDEX={}", walletIndex);
    } else {
        println("AGENTIC_NEXT_WALLET_INDEX={}", targetIndex);
    }
    println("AGENTIC_WALLET_OWNER={}", owner);
    println("AGENTIC_DELEGATE_PUBLIC_KEY={}", formatPublicKey(delegatePublicKey));
    confirmSend();

    val wallet = deployAgenticWallet(
        collection,
        admin,
        walletIndex,
        attachAmount,
        AgenticWalletInitParams.createPayloadAuto(
            owner,
            content,
            delegatePublicKey,
            forwardAmount,
            forwardPayload,
        ),
        value,
    );

    printAgenticWalletInfo(wallet);
}
