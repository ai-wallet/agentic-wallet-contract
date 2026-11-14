import "@acton/io"
import "@acton/emulation/scripts"

import "@wrappers/AgenticWallet.gen"
import "@wrappers/send"
import "@wrappers/utils"

import "@scripts/utils/common"
import "@scripts/utils/wallet"

fun main() {
    printNetwork();
    val wallet = promptAgenticWallet();
    val keyPair = delegateKeyPair();
    println("AGENTIC_DELEGATE_PUBLIC_KEY={}", formatPublicKey(keyPair.publicKey));
    assertDelegateKeyMatches(wallet, keyPair.publicKey);

    // with --tonconnect, only internal works: Acton rejects external messages there
    val viaInternal = signedViaInternal();
    val funder: ActonWallet? = viaInternal
        ? promptSigner("AGENTIC_FUNDER_SIGNER", "Select the signer paying for the request")
        : null;
    val value: coins = viaInternal ? promptMessageValue() : 0;
    val (recipient, action) = promptTransfer();
    println("AGENTIC_WALLET={}", wallet.address);
    println("AGENTIC_SIGNED_VIA={}", viaInternal ? "internal" : "external");
    confirmSend();

    val validUntil = blockchain.now() + VALID_FOR_SECONDS;

    // the script reads the seqno right before signing
    if (viaInternal) {
        val request = createInternalSignedRequest(
            keyPair,
            wallet.address,
            wallet.seqno(),
            [action],
            validUntil,
        );
        assertReached(
            wallet.sendSignedRequest(funder!.address, request, { value, bounce: true }).confirm(),
            recipient,
        );
    } else {
        val request = createExternalSignedRequest(
            keyPair,
            wallet.address,
            wallet.seqno(),
            [action],
            validUntil,
        );
        assertReached(wallet.sendExternalSignedRequest(request).confirm(), recipient);
    }

    printAgenticWalletInfo(wallet);
}
