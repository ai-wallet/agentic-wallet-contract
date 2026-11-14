import "@acton/crypto"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/errors"
import "@contracts/messages"
import "@tests/fixtures"
import "@tests/utils"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/send"
import "@wrappers/utils"
import "@tests/w5/utils"

get fun `test w5: signed internal should send a transfer`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    val body = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
    );

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });

    val fee = receipt.at(1).tx.load().totalFees.grams;
    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore + forwardValue - fee);
}

/// Signed requests can not give authority. The wallet rejects a self-message from the delegate
/// that sets a new delegate key.
get fun `test w5: signed internal should not set a delegate key via self-message`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val newDelegate = namedKeyPair("newDelegate");

    val body = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            selfMessageAction(
                wallet,
                ChangeWalletDelegate {
                    queryId: 0,
                    newDelegatePublicKey: newDelegate.publicKey as uint256,
                }.toCell(),
            ),
        ],
    );

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveFailedTx<ChangeWalletDelegate>({
        from: wallet.address,
        to: wallet.address,
        exitCode: Errors.NotFromOwner,
    });
    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
}

get fun `test w5: signed internal should send two transfers in order`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val testReceiver1 = randomAddress("test-receiver-1");
    val forwardValue1 = grams("0.001");

    val testReceiver2 = testing.treasury("receiver-2");
    val forwardValue2 = grams("0.002");

    val receiver1BalanceBefore = testing.getAccountBalance(testReceiver1);
    val receiver2BalanceBefore = testing.getAccountBalance(testReceiver2.address);

    val body = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            sendMessageAction(testReceiver1, forwardValue1),
            sendMessageAction(testReceiver2.address, forwardValue2),
        ],
    );

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveTx({
        from: wallet.address,
        to: testReceiver1,
        value: forwardValue1,
    });

    expect(receipt).toHaveTx({
        from: wallet.address,
        to: testReceiver2.address,
        value: forwardValue2,
    });

    // actions run in array order: receiver1 first (at index 1), receiver2 second (at index 2)
    val fee1 = receipt.at(1).tx.load().totalFees.grams;
    val fee2 = receipt.at(2).tx.load().totalFees.grams;

    val receiver1BalanceAfter = testing.getAccountBalance(testReceiver1);
    val receiver2BalanceAfter = testing.getAccountBalance(testReceiver2.address);
    expect(receiver1BalanceAfter).toEqual(receiver1BalanceBefore + forwardValue1 - fee1);
    expect(receiver2BalanceAfter).toEqual(receiver2BalanceBefore + forwardValue2 - fee2);
}

/// Signed requests can not give authority. The transfer goes out, but the wallet rejects the
/// self-messages that set a new delegate key and a new owner.
get fun `test w5: signed internal should send a transfer but not grant delegate or owner`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val newDelegate = namedKeyPair("newDelegate");
    val newOwner = randomAddress("new-owner");
    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    val body = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            sendMessageAction(testReceiver, forwardValue),
            selfMessageAction(
                wallet,
                ChangeWalletDelegate {
                    queryId: 0,
                    newDelegatePublicKey: newDelegate.publicKey as uint256,
                }.toCell(),
            ),
            selfMessageAction(wallet, changeOwnerBody(newOwner)),
        ],
    );

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });

    val fee = receipt.at(1).tx.load().totalFees.grams;
    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore + forwardValue - fee);

    expect(receipt).toHaveFailedTx<ChangeWalletDelegate>({
        from: wallet.address,
        to: wallet.address,
        exitCode: Errors.NotFromOwner,
    });
    expect(receipt).toHaveFailedTx<ChangeWalletOwner>({
        from: wallet.address,
        to: wallet.address,
        exitCode: Errors.NotFromOwner,
    });
    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
}

/// Signed requests also can not remove authority. The wallet rejects a self-message from the
/// delegate that removes the delegate key, and the next signed request still works.
get fun `test w5: signed internal should not clear the delegate key via self-message`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    var seqno = 0;

    // try to remove the delegate key
    val body1 = createInternalSignedRequest(
        keyPair,
        wallet.address,
        seqno,
        [
            selfMessageAction(
                wallet,
                ChangeWalletDelegate {
                    queryId: 0,
                    newDelegatePublicKey: 0,
                }.toCell(),
            ),
        ],
    );
    val receipt1 = wallet.sendSignedRequest(relayer.address, body1, { value: grams("0.1") });
    seqno += 1;

    expect(receipt1).toHaveFailedTx<ChangeWalletDelegate>({
        from: wallet.address,
        to: wallet.address,
        exitCode: Errors.NotFromOwner,
    });
    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);

    // the key still works
    val testReceiver = randomAddress("test-receiver");
    val body2 = createInternalSignedRequest(
        keyPair,
        wallet.address,
        seqno,
        [sendMessageAction(testReceiver, grams("0.001"))],
    );
    val receipt2 = wallet.sendSignedRequest(relayer.address, body2, { value: grams("0.1") });

    expect(receipt2).toHaveTx({ from: wallet.address, to: testReceiver });
    expect(wallet.seqno()).toEqual(2);
}

/// Only send-message actions are permitted. The wallet rejects a reserve action, and the whole
/// transaction reverts, including the seqno.
get fun `test w5: signed internal should fail with a reserve action`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val reserveAction = reserveActionList();
    val body = createInternalSignedRequestRaw(keyPair, wallet.address, 0, reserveAction);

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveTx({ exitCode: Errors.InvalidC5 });
    expect(wallet.seqno()).toEqual(0);
}

get fun `test w5: signed internal should fail with a set-code action`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    // set-code action (opcode 0xad4de08e) with the shape of a send action, to pass the size checks
    val setCodeAction = rawActionList(0xad4de08e, SEND_MODE_IGNORE_ERRORS, createEmptyCell());
    val body = createInternalSignedRequestRaw(keyPair, wallet.address, 0, setCodeAction);

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveTx({ exitCode: Errors.InvalidC5 });
    expect(wallet.seqno()).toEqual(0);
}

/// Signed requests can not transfer the wallet. The wallet rejects a self-message from the
/// delegate that transfers the wallet.
get fun `test w5: signed internal should not transfer the wallet via self-message`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val newOwner = randomAddress("new-owner");

    val body = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [selfMessageAction(wallet, changeOwnerBody(newOwner))],
    );

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveFailedTx<ChangeWalletOwner>({
        from: wallet.address,
        to: wallet.address,
        exitCode: Errors.NotFromOwner,
    });

    // the owner and the delegate key do not change
    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
}

/// Signed requests can not act as the owner. The wallet ignores a self-message from the delegate
/// with an owner action and sends nothing.
get fun `test w5: signed internal should not run owner actions via self-message`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    val testReceiver = randomAddress("test-receiver");

    val body = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            selfMessageAction(
                wallet,
                OwnerActionRequest {
                    queryId: 0,
                    outActions: buildOutActions([sendMessageAction(testReceiver, grams("1"))]),
                }.toCell(),
            ),
        ],
    );

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveSuccessfulTx<OwnerActionRequest>({
        from: wallet.address,
        to: wallet.address,
    });
    expect(receipt).toNotHaveTx({ to: testReceiver });
}

get fun `test w5: signed internal should be ignored if signed over another payload`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);
    val outActions = [sendMessageAction(testReceiver, forwardValue)];

    // a request with correct data
    var body = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        outActions,
        blockchain.now() + 1000,
    );

    // sign a different payload (wrong seqno)
    val fakePayload = createInternalSignedRequest(
        keyPair,
        wallet.address,
        1,
        outActions,
        blockchain.now() + 1000,
    );
    body.signature = fakePayload.signature;

    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    // the wallet ignores a bad signature: it accepts the message (exit 0) and runs no actions
    expect(receipt).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(receipt).toNotHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });

    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore);
    expect(wallet.seqno()).toEqual(0);
    wallet.expectIgnored(receipt, relayer.address, dataHashBefore);
}

get fun `test w5: signed internal should be ignored if signed by another key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    // sign with a different key
    val fakeKeyPair = namedKeyPair("fakeKeyPair");
    val body = createInternalSignedRequest(
        fakeKeyPair,
        wallet.address,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
    );

    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(receipt).toNotHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });

    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore);
    expect(wallet.seqno()).toEqual(0);
    wallet.expectIgnored(receipt, relayer.address, dataHashBefore);
}

get fun `test w5: signed internal should fail with a wrong seqno`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    // wrong seqno (1 instead of 0)
    val body = createInternalSignedRequest(
        keyPair,
        wallet.address,
        1,
        [sendMessageAction(testReceiver, forwardValue)],
    );

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveTx({ exitCode: Errors.InvalidSeqno });

    expect(receipt).toNotHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });

    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore);
}

get fun `test w5: signed internal should fail after validUntil`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    // expired validUntil (in the past)
    val body = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
        1,
    );

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveTx({ exitCode: Errors.Expired });

    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore);
}

get fun `test w5: signed internal should fail when validUntil equals now`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    val body = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
        blockchain.now(),
    );

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveTx({ exitCode: Errors.Expired });

    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore);
}

/// The request names the wallet that it is signed for.
get fun `test w5: signed internal should fail if signed for another wallet`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    // wrong wallet address
    val body = createInternalSignedRequest(
        keyPair,
        randomAddress("other-wallet"),
        0,
        [sendMessageAction(testReceiver, forwardValue)],
    );

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveTx({ exitCode: Errors.InvalidWalletAddress });

    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore);
}

get fun `test w5: internal with a signed external body should be ignored`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");

    // the external signed request instead of the internal one
    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
        blockchain.now() + 1000,
    );

    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendAny(relayer.address, body.toCell(), { value: grams("0.1") });

    expect(receipt).toHaveSuccessfulTx({ from: relayer.address, to: wallet.address });
    expect(receipt).toNotHaveTx({ from: wallet.address });
    expect(wallet.seqno()).toEqual(0);
    wallet.expectIgnored(receipt, relayer.address, dataHashBefore);
}

get fun `test w5: internal with an empty body should be ignored`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendAny(relayer.address, createEmptyCell(), { value: grams("0.1") });

    expect(receipt).toHaveSuccessfulTx({ from: relayer.address, to: wallet.address });
    expect(receipt).toNotHaveTx({ from: wallet.address });
    expect(wallet.seqno()).toEqual(0);
    wallet.expectIgnored(receipt, relayer.address, dataHashBefore);
}

fun buildSignedInternalBodyWithPayloadBits(keyPair: KeyPair, payloadBits: int): cell {
    var b = beginCell().storeUint(0xc369a095, 32);
    var rest = payloadBits - 32;
    while (rest > 0) {
        val n = min(rest, 256);
        b.storeUint(0, n);
        rest -= n;
    }
    val payload = b.endCell();
    val signature = crypto.sign(keyPair.privateKey, payload);
    return beginCell().storeSlice(payload.beginParse()).storeSlice(signature).endCell();
}

get fun `test w5: signed internal opcode alone should be ignored`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val body = beginCell().storeUint(0xc369a095, 32).endCell(); // InternalSignedRequest

    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendAny(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });
    wallet.expectIgnored(receipt, relayer.address, dataHashBefore);
}

/// The signed header is opcode + walletAddress + validUntil + seqno = 363 bits.
get fun `test w5: signed internal shorter than the signed header should be ignored`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val body = buildSignedInternalBodyWithPayloadBits(keyPair, 362);

    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendAny(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(wallet.seqno()).toEqual(0);
    wallet.expectIgnored(receipt, relayer.address, dataHashBefore);
}

get fun `test w5: signed internal with a zero signature should be ignored`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val body = beginCell()
        .storeUint(0xc369a095, 32) // InternalSignedRequest
        .storeUint(0, 256)
        .storeUint(0, 256)
        .storeUint(0, 256)
        .storeUint(0, 75) // 843 zero bits after the opcode: header and signature
        .endCell();

    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendAny(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });
    wallet.expectIgnored(receipt, relayer.address, dataHashBefore);
}

get fun `test w5: internal with a text comment should be accepted`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val body: string = "Hello";

    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendAny(relayer.address, body.toCell(), { value: grams("0.1") });

    expect(receipt).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });
    wallet.expectIgnored(receipt, relayer.address, dataHashBefore);
}

get fun `test w5: internal with a long text comment should be accepted`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val body: string = "Hello world Hello world Hello world Hello world Hello world Hello world Hello world Hello world Hello world Hello world Hello world Hello world Hello world Hello world Hello world Hello world Hello world Hello world Hello world Hello world";

    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendAny(relayer.address, body.toCell(), { value: grams("0.1") });

    expect(receipt).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });
    wallet.expectIgnored(receipt, relayer.address, dataHashBefore);
}

/// Only the owner can disable signed requests. The wallet rejects a message from
/// another sender that removes the delegate key.
get fun `test w5: non-owner should not clear the delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val receipt = wallet.sendChangeWalletDelegate(
        relayer.address,
        0,
        0,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt).toHaveFailedTx<ChangeWalletDelegate>({
        from: relayer.address,
        to: wallet.address,
        exitCode: Errors.NotFromOwner,
    });

    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
}

/// If the owner sets the current delegate key again, the change succeeds and only increments
/// the seqno.
get fun `test w5: owner setting the same delegate key should only increment the seqno`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val receipt = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        keyPair.publicKey as uint256,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt).toHaveSuccessfulTx<ChangeWalletDelegate>({
        from: owner.address,
        to: wallet.address,
    });

    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
    expect(wallet.seqno()).toEqual(1);
}

/// The owner disables signed requests when it removes the delegate key. The seqno increments.
get fun `test w5: owner should clear the delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val receipt = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        0,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt).toHaveSuccessfulTx({
        from: owner.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(wallet.getPublicKey()).toEqual(0);
    expect(wallet.seqno()).toEqual(1);
}

/// The owner first changes the delegate key, then removes it in a different transaction.
get fun `test w5: owner should rotate then clear the delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val newDelegate = namedKeyPair("newDelegate");

    val receipt1 = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        newDelegate.publicKey as uint256,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt1).toHaveSuccessfulTx({
        from: owner.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(wallet.getPublicKey()).toEqual(newDelegate.publicKey);

    val receipt2 = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        0,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt2).toHaveSuccessfulTx({
        from: owner.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(wallet.getPublicKey()).toEqual(0);
    expect(wallet.seqno()).toEqual(2);
}

/// The owner removes the delegate key and sets it again. Signed requests work again.
get fun `test w5: signed internal should succeed after the owner restores the delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    wallet.sendChangeWalletDelegate(owner.address, 0, 0, { value: grams("0.1"), bounce: true });
    expect(wallet.getPublicKey()).toEqual(0);

    val receipt = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        keyPair.publicKey as uint256,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt).toHaveSuccessfulTx({
        from: owner.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
    expect(wallet.seqno()).toEqual(2);

    // a signed transfer works again
    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    val signedBody = createInternalSignedRequest(
        keyPair,
        wallet.address,
        2,
        [sendMessageAction(testReceiver, forwardValue)],
    );

    val receipt2 = wallet.sendSignedRequest(
        relayer.address,
        signedBody,
        { value: grams("0.1") },
    );

    expect(receipt2).toHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });

    val fee = receipt2.at(1).tx.load().totalFees.grams;
    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore + forwardValue - fee);
}

/// The owner removes a delegate key that is already removed. The request succeeds and has no
/// effect.
get fun `test w5: owner clearing the delegate key twice should be a no-op`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    wallet.sendChangeWalletDelegate(owner.address, 0, 0, { value: grams("0.1"), bounce: true });

    val receipt = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        0,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt).toHaveSuccessfulTx<ChangeWalletDelegate>({
        from: owner.address,
        to: wallet.address,
    });

    expect(wallet.getPublicKey()).toEqual(0);
}

/// After the owner removes the delegate key, the wallet ignores a signed internal request.
get fun `test w5: signed internal should be ignored after the owner clears the delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val receipt1 = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        0,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt1).toHaveSuccessfulTx({
        from: owner.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(wallet.getPublicKey()).toEqual(0);
    expect(wallet.seqno()).toEqual(1);

    // the wallet ignores a signed transfer: there is no key to check it
    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    val signedBody = createInternalSignedRequest(
        keyPair,
        wallet.address,
        1,
        [sendMessageAction(testReceiver, forwardValue)],
    );

    val dataHashBefore = wallet.dataHash();
    val receipt2 = wallet.sendSignedRequest(
        relayer.address,
        signedBody,
        { value: grams("0.1") },
    );

    expect(receipt2).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(receipt2).toNotHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });

    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore);
    expect(wallet.seqno()).toEqual(1);
    wallet.expectIgnored(receipt2, relayer.address, dataHashBefore);
}
