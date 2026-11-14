import "@acton/crypto"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/big_array"

import "@contracts/errors"
import "@contracts/messages"
import "@tests/fixtures"
import "@tests/utils"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/utils"
import "@tests/w5/utils"

get fun `test w5: signed external should send a transfer`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
    );

    val receipt = wallet.sendExternalSigned(body)!;

    expect(receipt.size()).toEqual(2);

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
get fun `test w5: signed external should not set a delegate key via self-message`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val newDelegate = namedKeyPair("newDelegate");

    val body = createExternalSignedRequest(
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

    val receipt = wallet.sendExternalSigned(body)!;

    expect(receipt.size()).toEqual(2);
    expect(receipt).toHaveFailedTx<ChangeWalletDelegate>({
        from: wallet.address,
        to: wallet.address,
        exitCode: Errors.NotFromOwner,
    });

    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
}

get fun `test w5: signed external should send a transfer to a deployed wallet`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val receiver = testing.treasury("receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(receiver.address);

    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(receiver.address, forwardValue)],
    );

    val receipt = wallet.sendExternalSigned(body)!;

    expect(receipt.size()).toEqual(2);

    expect(receipt).toHaveTx({
        from: wallet.address,
        to: receiver.address,
        value: forwardValue,
    });

    val fee = receipt.at(1).tx.load().totalFees.grams;
    val receiverBalanceAfter = testing.getAccountBalance(receiver.address);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore + forwardValue - fee);
}

get fun `test w5: signed external should send two transfers in order`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val testReceiver1 = randomAddress("test-receiver-1");
    val forwardValue1 = grams("0.001");

    val testReceiver2 = testing.treasury("receiver-2");
    val forwardValue2 = grams("0.002");

    val receiver1BalanceBefore = testing.getAccountBalance(testReceiver1);
    val receiver2BalanceBefore = testing.getAccountBalance(testReceiver2.address);

    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            sendMessageAction(testReceiver1, forwardValue1),
            sendMessageAction(testReceiver2.address, forwardValue2),
        ],
    );

    val receipt = wallet.sendExternalSigned(body)!;

    expect(receipt.size()).toEqual(3);

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
get fun `test w5: signed external should send a transfer but not grant delegate or owner`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val newDelegate = namedKeyPair("newDelegate");
    val newOwner = randomAddress("new-owner");
    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    val body = createExternalSignedRequest(
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
            selfMessageAction(
                wallet,
                changeOwnerBody(newOwner),
            ),
        ],
    );

    val receipt = wallet.sendExternalSigned(body)!;

    expect(receipt.size()).toEqual(4);

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
/// delegate that removes the delegate key.
get fun `test w5: signed external should not clear the delegate key via self-message`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
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

    val receipt = wallet.sendExternalSigned(body)!;

    expect(receipt).toHaveFailedTx<ChangeWalletDelegate>({
        from: wallet.address,
        to: wallet.address,
        exitCode: Errors.NotFromOwner,
    });
    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
    expect(wallet.seqno()).toEqual(1);
}

/// Only send-message actions are permitted. The wallet rejects a reserve action after it commits
/// the seqno.
get fun `test w5: signed external should fail with a reserve action`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val reserveAction = reserveActionList();
    val body = createExternalSignedRequestRaw(keyPair, wallet.address, 0, reserveAction);

    val receipt = wallet.sendExternalSigned(body);
    expect(receipt != null).toBeTrue();
    expect(receipt!).toHaveTx({ exitCode: Errors.InvalidC5 });
    expect(receipt!).toNotHaveTx({ from: wallet.address });
    expect(wallet.seqno()).toEqual(1);
}

get fun `test w5: signed external should fail with a set-code action`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    // set-code action (opcode 0xad4de08e) with the shape of a send action, to pass the size checks
    val setCodeAction = rawActionList(0xad4de08e, SEND_MODE_IGNORE_ERRORS, createEmptyCell());
    val body = createExternalSignedRequestRaw(keyPair, wallet.address, 0, setCodeAction);

    val receipt = wallet.sendExternalSigned(body);
    expect(receipt != null).toBeTrue();
    expect(receipt!).toHaveTx({ exitCode: Errors.InvalidC5 });
    expect(receipt!).toNotHaveTx({ from: wallet.address });
    expect(wallet.seqno()).toEqual(1);
}

/// Signed requests can not transfer the wallet. The wallet rejects a self-message from the
/// delegate that transfers the wallet.
get fun `test w5: signed external should not transfer the wallet via self-message`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val newOwner = randomAddress("new-owner");

    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            selfMessageAction(
                wallet,
                changeOwnerBody(newOwner),
            ),
        ],
    );

    val receipt = wallet.sendExternalSigned(body)!;
    expect(receipt.size()).toEqual(2);
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
get fun `test w5: signed external should not run owner actions via self-message`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val testReceiver = randomAddress("test-receiver");

    val body = createExternalSignedRequest(
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

    val receipt = wallet.sendExternalSigned(body)!;
    expect(receipt.size()).toEqual(2);
    expect(receipt).toHaveSuccessfulTx<OwnerActionRequest>({
        from: wallet.address,
        to: wallet.address,
    });
    expect(receipt).toNotHaveTx({ to: testReceiver });
}

get fun `test w5: signed external should be rejected if signed over another payload`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val outActions = [sendMessageAction(testReceiver, forwardValue)];

    // a request with correct data
    var body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        outActions,
        blockchain.now() + 1000,
    );
    // sign a different payload (wrong seqno)
    val fakePayload = createExternalSignedRequest(
        keyPair,
        wallet.address,
        1,
        outActions,
        blockchain.now() + 1000,
    );
    body.signature = fakePayload.signature;

    // a bad signature: the wallet rejects the external before it accepts the message
    wallet.expectExternalRejected(body.toCell(), Errors.InvalidSignature as int);

    expect(wallet.seqno()).toEqual(0);
}

get fun `test w5: signed external should be rejected if signed by another key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");

    // sign with a different key
    val fakeKeyPair = namedKeyPair("fakeKeyPair");
    val body = createExternalSignedRequest(
        fakeKeyPair,
        wallet.address,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
    );

    wallet.expectExternalRejected(body.toCell(), Errors.InvalidSignature as int);
    expect(wallet.seqno()).toEqual(0);
}

get fun `test w5: signed external should be rejected with a wrong seqno`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");

    // wrong seqno (1 instead of 0)
    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        1,
        [sendMessageAction(testReceiver, forwardValue)],
    );

    wallet.expectExternalRejected(body.toCell(), Errors.InvalidSeqno as int);
    expect(wallet.seqno()).toEqual(0);
}

get fun `test w5: signed external should be rejected after validUntil`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");

    // expired validUntil (in the past)
    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
        1,
    );

    wallet.expectExternalRejected(body.toCell(), Errors.Expired as int);
    expect(wallet.seqno()).toEqual(0);
}

get fun `test w5: signed external should be rejected when validUntil equals now`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
        blockchain.now(),
    );

    wallet.expectExternalRejected(body.toCell(), Errors.Expired as int);
    expect(wallet.seqno()).toEqual(0);

    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore);
}

/// The request names the wallet that it is signed for.
get fun `test w5: signed external should be rejected if signed for another wallet`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");

    // wrong wallet address
    val body = createExternalSignedRequest(
        keyPair,
        randomAddress("other-wallet"),
        0,
        [sendMessageAction(testReceiver, forwardValue)],
    );

    wallet.expectExternalRejected(body.toCell(), Errors.InvalidWalletAddress as int);
    expect(wallet.seqno()).toEqual(0);
}

get fun `test w5: external with a signed internal body should be rejected`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");

    // the internal signed request instead of the external one
    val body = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
    );

    wallet.expectExternalRejected(body.toCell(), Errors.InvalidMessageOperation as int);
    expect(wallet.seqno()).toEqual(0);
}

get fun `test w5: external with an empty body should be rejected`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    wallet.expectExternalRejected(createEmptyCell(), Errors.InvalidMessageOperation as int);
    expect(wallet.seqno()).toEqual(0);
}

get fun `test w5: external with a text comment should be rejected`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    // text comment: 0x00000000 prefix and then the text bytes
    val body = beginCell()
        .storeUint(0, 32)
        .storeUint(0x48656C6C6F, 40) // "Hello"
        .endCell();

    wallet.expectExternalRejected(body, Errors.InvalidMessageOperation as int);
    expect(wallet.seqno()).toEqual(0);
}

/// Only the owner can disable signed requests. After the owner removes the delegate key, the
/// wallet rejects a signed request.
get fun `test w5: signed external should be rejected after the owner clears the delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val change = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        0,
        { value: grams("0.05"), bounce: true },
    );
    expect(change).toHaveSuccessfulTx<ChangeWalletDelegate>({
        from: owner.address,
        to: wallet.address,
    });
    expect(wallet.getPublicKey()).toEqual(0);
    expect(wallet.seqno()).toEqual(1);

    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        1,
        [sendMessageAction(randomAddress("test-receiver"), grams("0.001"))],
    );

    wallet.expectExternalRejected(body.toCell(), Errors.InvalidSignature as int);
    expect(wallet.seqno()).toEqual(1);
}
