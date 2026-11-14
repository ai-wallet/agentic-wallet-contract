import "@acton/crypto"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/big_array"

import "@tests/fixtures"
import "@tests/utils"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/send"
import "@wrappers/utils"

get fun `test w5: owner should send a transfer`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    val receipt = wallet.sendOwnerActions(
        owner.address,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
        { value: grams("0.1") },
    );

    expect(receipt.size()).toEqual(2);

    expect(receipt).toHaveSuccessfulTx({ from: owner.address, to: wallet.address });

    expect(receipt).toHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });

    val fee = receipt.at(1).tx.load().totalFees.grams;
    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore + forwardValue - fee);
}

/// The owner sends two transfers, then sets a new delegate key in a different message.
get fun `test w5: owner should send two transfers, then set a new delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val newDelegate = namedKeyPair("newDelegate");
    val testReceiver1 = randomAddress("test-receiver-1");
    val testReceiver2 = randomAddress("test-receiver-2");
    val forwardValue1 = grams("0.001");
    val forwardValue2 = grams("0.0012");

    val receiver1BalanceBefore = testing.getAccountBalance(testReceiver1);
    val receiver2BalanceBefore = testing.getAccountBalance(testReceiver2);

    val receipt = wallet.sendOwnerActions(
        owner.address,
        0,
        [
            sendMessageAction(testReceiver1, forwardValue1),
            sendMessageAction(testReceiver2, forwardValue2),
        ],
        { value: grams("0.1") },
    );

    expect(receipt.size()).toEqual(3);

    expect(receipt).toHaveSuccessfulTx({ from: owner.address, to: wallet.address });

    expect(receipt).toHaveTx({
        from: wallet.address,
        to: testReceiver1,
        value: forwardValue1,
    });

    expect(receipt).toHaveTx({
        from: wallet.address,
        to: testReceiver2,
        value: forwardValue2,
    });

    val fee1 = receipt.at(1).tx.load().totalFees.grams;
    val fee2 = receipt.at(2).tx.load().totalFees.grams;

    val receiver1BalanceAfter = testing.getAccountBalance(testReceiver1);
    val receiver2BalanceAfter = testing.getAccountBalance(testReceiver2);
    expect(receiver1BalanceAfter).toEqual(receiver1BalanceBefore + forwardValue1 - fee1);
    expect(receiver2BalanceAfter).toEqual(receiver2BalanceBefore + forwardValue2 - fee2);

    val receipt2 = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        newDelegate.publicKey as uint256,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt2).toHaveSuccessfulTx({ from: owner.address, to: wallet.address });

    // the owner and the new delegate key both have authority
    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
    expect(wallet.getPublicKey()).toEqual(newDelegate.publicKey);
}

/// The owner sets a new delegate key, then removes it.
get fun `test w5: owner should set and then clear a delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val otherDelegate = namedKeyPair("otherDelegate");

    val receipt1 = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        otherDelegate.publicKey as uint256,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt1.size()).toEqual(1);

    expect(receipt1).toHaveSuccessfulTx({ from: owner.address, to: wallet.address });

    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
    expect(wallet.getPublicKey()).toEqual(otherDelegate.publicKey);

    val receipt2 = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        0,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt2.size()).toEqual(1);

    expect(receipt2).toHaveSuccessfulTx({ from: owner.address, to: wallet.address });

    // only the owner remains
    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
    expect(wallet.getPublicKey()).toEqual(0);
}

get fun `test w5: non-owner action request should be ignored`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val stranger = testing.treasury("stranger");
    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendOwnerActions(
        stranger.address,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
        { value: grams("0.1") },
    );

    expect(receipt.size()).toEqual(1);

    expect(receipt).toNotHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });

    // another contract can send a body with this opcode by accident, so the wallet accepts it
    // silently and does not throw
    expect(receipt).toHaveSuccessfulTx({
        from: stranger.address,
        to: wallet.address,
        exitCode: 0,
    });

    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore);
    wallet.expectIgnored(receipt, stranger.address, dataHashBefore);
}

get fun `test w5: owner should send a transfer with the delegate key cleared`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    // remove the delegate key
    wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        0,
        { value: grams("0.1"), bounce: true },
    );

    expect(wallet.getPublicKey()).toEqual(0);

    // the owner can still transfer
    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    val receipt = wallet.sendOwnerActions(
        owner.address,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
        { value: grams("0.1") },
    );

    expect(receipt.size()).toEqual(2);

    expect(receipt).toHaveSuccessfulTx({ from: owner.address, to: wallet.address });

    expect(receipt).toHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });

    val fee = receipt.at(1).tx.load().totalFees.grams;
    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore + forwardValue - fee);
}

/// The owner removes the delegate key and sets it again without sending messages. Each change
/// increments the seqno, and signed requests work again.
get fun `test w5: owner should clear and restore the delegate key, then signed internals work`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    // each of the two key changes increments the seqno
    val seqno = 2;

    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);

    // remove the delegate key
    val clearReceipt = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        0,
        { value: grams("0.1"), bounce: true },
    );

    expect(clearReceipt.size()).toEqual(1);

    expect(clearReceipt).toHaveSuccessfulTx({
        from: owner.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(wallet.getPublicKey()).toEqual(0);

    // set the delegate key again
    val receipt = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        keyPair.publicKey as uint256,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt.size()).toEqual(1);

    expect(receipt).toHaveSuccessfulTx({
        from: owner.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);

    val contractSeqno = wallet.seqno();
    expect(contractSeqno).toEqual(seqno);

    // a signed transfer shows that the delegate key works again
    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");
    val receiverBalanceBefore = testing.getAccountBalance(testReceiver);

    val signedBody = createInternalSignedRequest(
        keyPair,
        wallet.address,
        seqno,
        [sendMessageAction(testReceiver, forwardValue)],
    );

    val receipt2 = wallet.sendSignedRequest(
        owner.address,
        signedBody,
        { value: grams("0.1") },
    );

    expect(receipt2.size()).toEqual(2);

    expect(receipt2).toHaveSuccessfulTx({ from: owner.address, to: wallet.address });

    expect(receipt2).toHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });

    val fee = receipt2.at(1).tx.load().totalFees.grams;
    val receiverBalanceAfter = testing.getAccountBalance(testReceiver);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore + forwardValue - fee);
}
