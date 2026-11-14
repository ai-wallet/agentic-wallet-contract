import "@acton/build"
import "@acton/crypto"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/types/big_array"

import "@contracts/errors"
import "@contracts/messages"
import "@contracts/storage-collection"
import "@tests/fixtures"
import "@tests/utils"
import "@wrappers/AgenticCollection.gen"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/send"
import "@wrappers/utils"
import "@tests/w5/utils"

/// The same account hash on the masterchain: a different address that only looks the same.
fun masterchainAlias(addr: address): address {
    val (_, hash) = addr.getWorkchainAndHash();
    return beginCell().storeUint(4, 3).storeInt(-1, 8).storeUint(hash, 256).toSlice() as address;
}

// ==================== Basic ====================

get fun `test w5: wallet should accept plain, text and unknown-opcode transfers`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val stranger = testing.treasury("stranger");

    // plain transfer, no body
    val receipt1 = wallet.sendAny(
        stranger.address,
        createEmptyCell(),
        { value: grams("1"), bounce: false },
    );
    expect(receipt1).toHaveSuccessfulTx({
        from: stranger.address,
        to: wallet.address,
        exitCode: 0,
    });

    // text comment transfer
    val textBody: string = "Hey, bruh!";
    val receipt2 = wallet.sendAny(
        stranger.address,
        textBody.toCell(),
        { value: grams("1"), bounce: false },
    );
    expect(receipt2).toHaveSuccessfulTx({
        from: stranger.address,
        to: wallet.address,
        exitCode: 0,
    });

    // transfer with a non-wallet opcode
    val randomBody = beginCell()
        .storeUint(0xdeadbeef, 32)
        .storeUint(blockchain.now(), 64)
        .endCell();
    val receipt3 = wallet.sendAny(
        stranger.address,
        randomBody,
        { value: grams("1"), bounce: false },
    );
    expect(receipt3).toHaveSuccessfulTx({
        from: stranger.address,
        to: wallet.address,
        exitCode: 0,
    });
}

// ==================== Actions: External ====================

get fun `test w5: signed external should send 255 messages`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val testReceiver = testing.treasury("receiver");

    var outActions: array<SendMessageAction> = [];
    var i = 0;
    while (i < 255) {
        outActions.push(
            sendMessageAction(
                testReceiver.address,
                grams("0.001"),
                beginCell().storeUint(i, 32).endCell(),
            ),
        );
        i += 1;
    }

    val body = createExternalSignedRequest(keyPair, wallet.address, 0, outActions);

    val receipt = wallet.sendExternalSigned(body)!;

    // 1 wallet transaction + 255 message transactions
    expect(receipt.size()).toEqual(256);
}

get fun `test w5: signed external should fail without the ignore-errors send mode`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val testReceiver = randomAddress("test-receiver");

    // mode +1 without ignore-errors fails for externals
    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            sendMessageAction(
                testReceiver,
                grams("0.001"),
                null,
                SEND_MODE_PAY_FEES_SEPARATELY, // no ignore-errors
            ),
        ],
    );

    // the failure is after the wallet accepts the message, so the chain includes the transaction
    val receipt = wallet.sendExternalSigned(body)!;

    expect(receipt).toHaveTx({
        exitCode: Errors.ExternalSendMessageMustHaveIgnoreErrorsSendMode,
    });
    expect(receipt).toNotHaveTx({ from: wallet.address });
    expect(receipt).toNotHaveTx({ to: testReceiver });
}

/// The wallet rejects an empty action list, but the external seqno is already committed.
get fun `test w5: signed external with an empty action list should fail and consume the seqno`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    expect(wallet.seqno()).toEqual(0);

    val body = createExternalSignedRequestRaw(keyPair, wallet.address, 0, createEmptyCell());
    val receipt = wallet.sendExternalSigned(body)!;

    expect(receipt).toHaveTx({ exitCode: Errors.InvalidC5 });
    expect(receipt).toNotHaveTx({ from: wallet.address });
    expect(wallet.seqno()).toEqual(1);
}

/// The transfer goes out, but the wallet rejects the self-message that sets a new delegate key.
get fun `test w5: signed external should send a transfer but not set a delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val newDelegate = namedKeyPair("newDelegate");
    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");

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
        ],
    );

    val receipt = wallet.sendExternalSigned(body)!;

    expect(receipt).toHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });
    expect(receipt).toHaveFailedTx<ChangeWalletDelegate>({
        from: wallet.address,
        to: wallet.address,
        exitCode: Errors.NotFromOwner,
    });

    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
    expect(wallet.seqno()).toEqual(1);
}

get fun `test w5: signed external self-message clearing the delegate key should fail with NotFromOwner`() {
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

    expect(receipt).toHaveTx({ exitCode: Errors.NotFromOwner });

    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
}

get fun `test w5: signed external should send an external-out message`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val testPayload = 12345;
    val testBody = beginCell().storeUint(testPayload, 32).endCell();

    // external address: addr_extern$01 + len(32) + payload
    val extAddrBuilder = beginCell().storeUint(1, 2).storeUint(32, 9).storeUint(testPayload, 32);

    val extOutMsg = createExternalLogMessage({ dest: extAddrBuilder, body: testBody });

    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            SendMessageAction {
                sendMode: SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS,
                outMsg: extOutMsg.messageCell,
            },
        ],
    );

    val receipt = wallet.sendExternalSigned(body)!;

    expect(receipt).toHaveTx({ exitCode: 0 });

    expect(wallet.seqno()).toEqual(1);

    expect(receipt.findExternalOutMessage({ from: wallet.address }) != null).toBeTrue();
}

/// A delegate can not transfer the wallet to a masterchain owner (or any owner) with a
/// self-message. It fails the owner check before the workchain check. The test "owner should not
/// transfer the wallet to a masterchain address" checks the workchain check.
get fun `test w5: signed external should not transfer the wallet to a masterchain owner`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val mcOwner = randomAddress("mc-owner", -1);

    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [selfMessageAction(wallet, changeOwnerBody(mcOwner))],
    );

    val receipt = wallet.sendExternalSigned(body)!;

    expect(receipt).toHaveTx({ exitCode: Errors.NotFromOwner });

    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
}

// ==================== Actions: Internal ====================

get fun `test w5: signed internal should send 255 messages`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val testReceiver = testing.treasury("receiver");

    var outActions: array<SendMessageAction> = [];
    var i = 0;
    while (i < 255) {
        outActions.push(
            sendMessageAction(
                testReceiver.address,
                grams("0.001"),
                beginCell().storeUint(i, 32).endCell(),
                SEND_MODE_PAY_FEES_SEPARATELY,
            ),
        );
        i += 1;
    }

    val body = createInternalSignedRequest(keyPair, wallet.address, 0, outActions);

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("10") });

    // the wallet transaction + 255 outgoing transactions
    expect(receipt).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });
    expect(receipt.size()).toEqual(256);

    expect(wallet.seqno()).toEqual(1);
}

get fun `test w5: signed internal should send messages with and without ignore-errors`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    var seqno = 0;

    val testReceiver = testing.treasury("receiver");

    // internal works with ignore-errors
    val body1 = createInternalSignedRequest(
        keyPair,
        wallet.address,
        seqno,
        [
            sendMessageAction(
                testReceiver.address,
                grams("0.001"),
                null,
                SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
            ),
        ],
    );
    val receipt1 = wallet.sendSignedRequest(relayer.address, body1, { value: grams("0.1") });
    expect(receipt1).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });
    expect(receipt1).toHaveTx({ from: wallet.address, to: testReceiver.address });
    seqno += 1;

    // internal also works without ignore-errors, unlike external
    val body2 = createInternalSignedRequest(
        keyPair,
        wallet.address,
        seqno,
        [
            sendMessageAction(
                testReceiver.address,
                grams("0.001"),
                null,
                SEND_MODE_PAY_FEES_SEPARATELY,
            ),
        ],
    );
    val receipt2 = wallet.sendSignedRequest(relayer.address, body2, { value: grams("0.1") });
    expect(receipt2).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });
    expect(receipt2).toHaveTx({ from: wallet.address, to: testReceiver.address });
    seqno += 1;

    expect(wallet.seqno()).toEqual(seqno);
}

/// The wallet rejects an empty action list, and the internal transaction reverts, including the
/// seqno.
get fun `test w5: signed internal with an empty action list should fail and keep the seqno`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    expect(wallet.seqno()).toEqual(0);

    val body = createInternalSignedRequestRaw(keyPair, wallet.address, 0, createEmptyCell());
    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveTx({ exitCode: Errors.InvalidC5 });
    expect(wallet.seqno()).toEqual(0);
}

/// The transfer goes out, but the wallet rejects the self-message that sets a new delegate key.
get fun `test w5: signed internal should send a transfer but not set a delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val newDelegate = namedKeyPair("newDelegate");
    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");

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
        ],
    );

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });
    expect(receipt).toHaveFailedTx<ChangeWalletDelegate>({
        from: wallet.address,
        to: wallet.address,
        exitCode: Errors.NotFromOwner,
    });

    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
    expect(wallet.seqno()).toEqual(1);
}

get fun `test w5: signed internal self-message clearing the delegate key should fail with NotFromOwner`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val body = createInternalSignedRequest(
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

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveTx({ exitCode: Errors.NotFromOwner });

    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
}

// ==================== Actions: Owner ====================

get fun `test w5: owner should send 255 messages`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val testReceiver = testing.treasury("receiver");

    var outActions: array<SendMessageAction> = [];
    var i = 0;
    while (i < 255) {
        outActions.push(
            sendMessageAction(
                testReceiver.address,
                grams("0.001"),
                beginCell().storeUint(i, 32).endCell(),
            ),
        );
        i += 1;
    }

    val receipt = wallet.sendOwnerActions(
        owner.address,
        0,
        outActions,
        { value: grams("10") },
    );

    // the wallet transaction + 255 outgoing transactions
    expect(receipt).toHaveSuccessfulTx({
        from: owner.address,
        to: wallet.address,
        exitCode: 0,
    });
    expect(receipt.size()).toEqual(256);
}

get fun `test w5: owner should send messages with and without ignore-errors`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val testReceiver = testing.treasury("receiver");

    // owner actions work with ignore-errors
    val receipt1 = wallet.sendOwnerActions(
        owner.address,
        0,
        [
            sendMessageAction(
                testReceiver.address,
                grams("0.001"),
                null,
                SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
            ),
        ],
        { value: grams("0.1") },
    );
    expect(receipt1).toHaveSuccessfulTx({
        from: owner.address,
        to: wallet.address,
        exitCode: 0,
    });
    expect(receipt1).toHaveTx({ from: wallet.address, to: testReceiver.address });

    // owner actions also work without ignore-errors, like internal
    val receipt2 = wallet.sendOwnerActions(
        owner.address,
        0,
        [
            sendMessageAction(
                testReceiver.address,
                grams("0.001"),
                null,
                SEND_MODE_PAY_FEES_SEPARATELY,
            ),
        ],
        { value: grams("0.1") },
    );
    expect(receipt2).toHaveSuccessfulTx({
        from: owner.address,
        to: wallet.address,
        exitCode: 0,
    });
    expect(receipt2).toHaveTx({ from: wallet.address, to: testReceiver.address });
}

get fun `test w5: owner action from the owner's masterchain alias should be ignored`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val mcAddress = masterchainAlias(owner.address);

    // owner action from the masterchain alias of the owner
    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");

    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendOwnerActions(
        mcAddress,
        0,
        [sendMessageAction(testReceiver, forwardValue)],
        { value: grams("0.1") },
    );

    // ignored: no transfer, no error
    expect(receipt).toHaveSuccessfulTx({
        from: mcAddress,
        to: wallet.address,
        exitCode: 0,
    });
    expect(receipt).toNotHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });
    wallet.expectIgnored(receipt, mcAddress, dataHashBefore);
}

/// Owner actions only send messages. The transfer goes out, but a self-message that sets a new
/// delegate key fails: the wallet is not its own owner. The seqno does not change.
get fun `test w5: owner action self-message should not set a delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val newDelegate = namedKeyPair("newDelegate");
    val testReceiver = randomAddress("test-receiver");
    val forwardValue = grams("0.001");

    val receipt = wallet.sendOwnerActions(
        owner.address,
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
        ],
        { value: grams("0.1") },
    );

    expect(receipt).toHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: forwardValue,
    });
    expect(receipt).toHaveFailedTx<ChangeWalletDelegate>({
        from: wallet.address,
        to: wallet.address,
        exitCode: Errors.NotFromOwner,
    });

    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
    // owner actions do not change the seqno
    expect(wallet.seqno()).toEqual(0);
}

// ==================== Malformed action list ====================

get fun `test w5: action list over 255 actions should fail on every path`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    var seqno = 0;

    val testReceiver = testing.treasury("receiver");

    // build the action list by hand: arrays hold at most 255 elements
    var c5 = createEmptyCell();
    var i = 0;
    while (i < 256) {
        val action = sendMessageAction(
            testReceiver.address,
            grams("0.001"),
            beginCell().storeUint(i, 32).endCell(),
        );
        c5 = beginCell()
            .storeRef(c5)
            .storeUint(0x0ec3c86d, 32)
            .storeUint(action.sendMode, 8)
            .storeRef(action.outMsg)
            .endCell();
        i += 1;
    }

    // with an external: it fails after the wallet accepts it, so the chain includes the transaction
    val extBody = createExternalSignedRequestRaw(keyPair, wallet.address, seqno, c5);
    val extReceipt = wallet.sendExternalSigned(extBody);
    if (extReceipt == null) {
        Assert.fail("External message was not accepted");
    }
    expect(extReceipt).toHaveTx({ exitCode: Errors.InvalidC5 });
    expect(extReceipt).toNotHaveTx({ from: wallet.address });
    seqno += 1;

    // via internal: bounces
    val intBody = createInternalSignedRequestRaw(keyPair, wallet.address, seqno, c5);
    val intReceipt = wallet.sendSignedRequest(owner.address, intBody, { value: grams("10") });
    expect(intReceipt).toHaveTx({ exitCode: Errors.InvalidC5 });

    // via owner
    val ownerBody = OwnerActionRequest {
        queryId: 0,
        outActions: c5,
    };
    val ownerReceipt = wallet.sendAny(
        owner.address,
        ownerBody.toCell(),
        { value: grams("10") },
    );
    expect(ownerReceipt).toHaveTx({ exitCode: Errors.InvalidC5 });

    expect(wallet.seqno()).toEqual(seqno);
}

// ==================== Delegate key ====================

get fun `test w5: owner should clear and restore the delegate key, incrementing the seqno each time`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val seqnoBefore = wallet.seqno();
    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);

    // remove the delegate key as the owner
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
    expect(wallet.seqno()).toEqual(seqnoBefore + 1);

    // set the delegate key again
    val receipt2 = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        keyPair.publicKey as uint256,
        { value: grams("0.1"), bounce: true },
    );
    expect(receipt2).toHaveSuccessfulTx({
        from: owner.address,
        to: wallet.address,
        exitCode: 0,
    });
    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
    expect(wallet.seqno()).toEqual(seqnoBefore + 2);
}

get fun `test w5: signed external should be rejected without a delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    // the seqno increments when the owner removes the key
    val seqno = 1;

    // remove the delegate key as the owner
    wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        0,
        { value: grams("0.1"), bounce: true },
    );

    expect(wallet.getPublicKey()).toEqual(0);

    // the wallet rejects a signed external before it accepts the message
    val testReceiver = randomAddress("test-receiver");
    val extBody = createExternalSignedRequest(
        keyPair,
        wallet.address,
        seqno,
        [sendMessageAction(testReceiver, grams("0.001"))],
    );

    wallet.expectExternalRejected(extBody.toCell(), Errors.InvalidSignature as int);
    expect(wallet.seqno()).toEqual(seqno);
}

/// With no delegate key, the wallet ignores a signed internal request: it accepts it and sends
/// nothing.
get fun `test w5: signed internal should be ignored without a delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    // the seqno increments when the owner removes the key
    val seqno = 1;

    // remove the delegate key as the owner
    wallet.sendChangeWalletDelegate(owner.address, 0, 0, { value: grams("0.1"), bounce: true });

    expect(wallet.getPublicKey()).toEqual(0);

    // the wallet ignores a signed internal
    val testReceiver = randomAddress("test-receiver");
    val intBody = createInternalSignedRequest(
        keyPair,
        wallet.address,
        seqno,
        [sendMessageAction(testReceiver, grams("0.001"))],
    );

    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendSignedRequest(relayer.address, intBody, { value: grams("0.1") });

    expect(receipt).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });
    expect(receipt).toNotHaveTx({ from: wallet.address, to: testReceiver });
    expect(wallet.seqno()).toEqual(seqno);
    wallet.expectIgnored(receipt, relayer.address, dataHashBefore);
}

/// After the owner removes the delegate key, the owner can still set a new key.
get fun `test w5: owner should set a new delegate key after clearing it`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    // remove the delegate key as the owner
    wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        0,
        { value: grams("0.1"), bounce: true },
    );

    expect(wallet.getPublicKey()).toEqual(0);

    // set another delegate key
    val newDelegate = namedKeyPair("newDelegate");
    val receipt = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        newDelegate.publicKey as uint256,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt).toHaveSuccessfulTx({
        from: owner.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(wallet.getPublicKey()).toEqual(newDelegate.publicKey);
}

/// After the owner removes the delegate key, the owner keeps control: owner actions still work.
get fun `test w5: owner should keep control after revoking the delegate`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    // set another delegate key
    val otherDelegate = namedKeyPair("otherDelegate");
    wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        otherDelegate.publicKey as uint256,
        { value: grams("0.1"), bounce: true },
    );

    expect(wallet.getPublicKey()).toEqual(otherDelegate.publicKey);

    // remove it
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

    // the owner remains in control
    val testReceiver = randomAddress("test-receiver");
    val receipt2 = wallet.sendOwnerActions(
        owner.address,
        0,
        [sendMessageAction(testReceiver, grams("0.001"))],
        { value: grams("0.1") },
    );
    expect(receipt2).toHaveTx({ from: wallet.address, to: testReceiver });
}

/// A wallet deployed without a delegate key ignores signed requests. The owner withdraws the
/// funds.
get fun `test w5: owner should withdraw from a wallet deployed without a delegate key`() {
    val keyPair = namedKeyPair("keyPair");

    val (wallet, owner) = deployAgenticWalletWithKey(0);
    val relayer = testing.treasury("relayer");

    expect(wallet.getPublicKey()).toEqual(0);

    val testReceiver = randomAddress("receiver");
    val outActions = [sendMessageAction(testReceiver, grams("0.001"))];
    val seqno = 0;

    // via signed internal: ignored
    val intBody = createInternalSignedRequest(keyPair, wallet.address, seqno, outActions);
    val intReceipt = wallet.sendSignedRequest(relayer.address, intBody, { value: grams("0.1") });
    expect(intReceipt).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });
    expect(intReceipt).toNotHaveTx({ from: wallet.address, to: testReceiver });

    // via signed external: rejected
    val extBody = createExternalSignedRequest(keyPair, wallet.address, seqno, outActions);
    wallet.expectExternalRejected(extBody.toCell(), Errors.InvalidSignature as int);

    expect(wallet.seqno()).toEqual(seqno);

    // via owner: withdrawn
    val ownerReceipt = wallet.sendOwnerActions(
        owner.address,
        0,
        outActions,
        { value: grams("0.1") },
    );
    expect(ownerReceipt).toHaveTx({ from: wallet.address, to: testReceiver });
}

// ==================== Malformed action: extra data/refs ====================

get fun `test w5: malformed action node should fail on every path`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    var seqno = 0;

    val testReceiver = randomAddress("test-receiver");
    val innerMsg = createMessage({
        bounce: false,
        value: grams("0.001"),
        dest: testReceiver,
    });

    // valid action node: ref(prev) | 0x0ec3c86d | mode:8 | ref(message)
    // as a standalone (no prev ref): 0x0ec3c86d | mode:8 | ref(message)
    val validActionBuilder = beginCell()
        .storeUint(0x0ec3c86d, 32)
        .storeUint(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS, 8)
        .storeRef(innerMsg.messageCell);
    val validActionCell = validActionBuilder.endCell();

    // noRef: action data without the message ref
    var noRefSlice = validActionCell.beginParse();
    noRefSlice.loadRef();
    val noRef = beginCell().storeSlice(noRefSlice).endCell();

    // excessiveData: valid action + 1 extra bit
    val excessiveData = beginCell()
        .storeSlice(validActionCell.beginParse())
        .storeUint(1, 1)
        .endCell();

    // truncated: valid action minus 1 bit, message ref kept
    var truncSlice = validActionCell.beginParse();
    val totalBits = truncSlice.remainingBitsCount();
    val truncated = beginCell()
        .storeSlice(truncSlice.loadBits(totalBits - 1))
        .storeRef(innerMsg.messageCell)
        .endCell();

    // extraRef: valid action + extra ref
    val extraRef = beginCell()
        .storeSlice(validActionCell.beginParse())
        .storeRef(beginCell().storeUint(0x0ec3c86d, 32).endCell())
        .endCell();

    val malformedPayloads: array<cell> = [excessiveData, truncated, extraRef, noRef];

    var i = 0;
    while (i < malformedPayloads.size()) {
        val payload = malformedPayloads.get(i);

        // wrap as an action list node: ref(empty_prev) | payload_slice
        val actionList = beginCell()
            .storeRef(createEmptyCell())
            .storeSlice(payload.beginParse())
            .endCell();

        // via internal
        val intBody = createInternalSignedRequestRaw(keyPair, wallet.address, seqno, actionList);
        val intReceipt = wallet.sendSignedRequest(
            relayer.address,
            intBody,
            { value: grams("1") },
        );
        expect(intReceipt).toHaveTx({ exitCode: Errors.InvalidC5 });

        // with an external: it fails after the wallet accepts it, so the chain includes the
        // transaction and the seqno increments
        val extBody = createExternalSignedRequestRaw(keyPair, wallet.address, seqno, actionList);
        val extReceipt = wallet.sendExternalSigned(extBody);
        if (extReceipt == null) {
            Assert.fail("External message was not accepted");
        }
        expect(extReceipt).toHaveTx({ exitCode: Errors.InvalidC5 });
        expect(extReceipt).toNotHaveTx({ from: wallet.address });
        seqno += 1;

        i += 1;
    }

    // via owner
    i = 0;
    while (i < malformedPayloads.size()) {
        val payload = malformedPayloads.get(i);

        val actionList = beginCell()
            .storeRef(createEmptyCell())
            .storeSlice(payload.beginParse())
            .endCell();

        val ownerBody = OwnerActionRequest {
            queryId: 0,
            outActions: actionList,
        };
        val ownerReceipt = wallet.sendAny(
            owner.address,
            ownerBody.toCell(),
            { value: grams("1") },
        );
        expect(ownerReceipt).toHaveTx({ exitCode: Errors.InvalidC5 });

        i += 1;
    }

    // the valid action still works
    val validC5 = beginCell()
        .storeRef(createEmptyCell())
        .storeSlice(validActionCell.beginParse())
        .endCell();
    val validIntBody = createInternalSignedRequestRaw(keyPair, wallet.address, seqno, validC5);
    val validReceipt = wallet.sendSignedRequest(
        relayer.address,
        validIntBody,
        { value: grams("1") },
    );
    expect(validReceipt).toHaveTx({
        from: wallet.address,
        to: testReceiver,
        value: grams("0.001"),
    });
}

// ==================== Send with init state ====================

/// The wallet deploys a new collection with itself as admin. It sends a message with init state.
get fun `test w5: signed external should deploy a contract with init state`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val newCollection = AgenticCollection.fromStorage(
        AgenticCollectionStorage.create(
            wallet.address,
            blockchain.globalId(),
            build("AgenticWallet"),
            emptyCollectionContent(),
            {
                numerator: 0,
                denominator: 1,
                royaltyAddress: wallet.address,
            },
            {
                maxWalletIndex: MAX_WALLET_INDEX_UNLIMITED,
                publicDeployEnabled: false,
                deployPrice: grams("1"),
                referralBps: 0,
                traitSetCount: 1,
            },
        ),
    );

    val deployMsg = createMessage({
        bounce: false,
        value: grams("1"),
        dest: { stateInit: newCollection.stateInit! },
    });

    val body = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            SendMessageAction {
                sendMode: SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
                outMsg: deployMsg.messageCell,
            },
        ],
    );

    val receipt = wallet.sendExternalSigned(body)!;

    expect(receipt).toHaveTx({ exitCode: 0 });

    val data = newCollection.getCollectionData();
    expect(data.nextWalletIndex).toEqual(0);
    expect(data.adminAddress).toEqual(wallet.address);
    expect(wallet.seqno()).toEqual(1);
}

// ==================== Cross-chain: internal & owner ====================

/// A delegate can not transfer the wallet to a masterchain owner (or any owner) with a
/// self-message. It fails the owner check before the workchain check. The test "owner should not
/// transfer the wallet to a masterchain address" checks the workchain check.
get fun `test w5: signed internal should not transfer the wallet to a masterchain owner`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val mcOwner = randomAddress("mc-owner-int", -1);

    val body = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [selfMessageAction(wallet, changeOwnerBody(mcOwner))],
    );

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveTx({ exitCode: Errors.NotFromOwner });

    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
}

/// The owner can not transfer the wallet to a masterchain address.
get fun `test w5: owner should not transfer the wallet to a masterchain address`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val mcOwner = randomAddress("mc-owner-act", -1);

    val receipt = wallet.sendAny(
        owner.address,
        changeOwnerBody(mcOwner),
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt).toHaveTx({ exitCode: Errors.InvalidWorkchain });

    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
}

/// The masterchain alias of the owner (same hash) is not the owner, so it can not remove the
/// delegate key.
get fun `test w5: owner's masterchain alias should not clear the delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val mcAlias = masterchainAlias(owner.address);

    val receipt = wallet.sendChangeWalletDelegate(
        mcAlias,
        0,
        0,
        { value: grams("0.1"), bounce: true },
    );

    expect(receipt).toHaveTx({ exitCode: Errors.NotFromOwner });

    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
}

// ==================== External-out: internal & owner ====================

get fun `test w5: signed internal should send an external-out message`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val testPayload = 54321;
    val testBody = beginCell().storeUint(testPayload, 32).endCell();

    val extAddrBuilder = beginCell().storeUint(1, 2).storeUint(32, 9).storeUint(testPayload, 32);
    val extOutMsg = createExternalLogMessage({ dest: extAddrBuilder, body: testBody });

    val body = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            SendMessageAction {
                sendMode: SEND_MODE_REGULAR,
                outMsg: extOutMsg.messageCell,
            },
        ],
    );

    val receipt = wallet.sendSignedRequest(relayer.address, body, { value: grams("0.1") });

    expect(receipt).toHaveSuccessfulTx({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(wallet.seqno()).toEqual(1);

    expect(receipt.findExternalOutMessage({ from: wallet.address }) != null).toBeTrue();
}

get fun `test w5: owner should send an external-out message`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val testPayload = 99999;
    val testBody = beginCell().storeUint(testPayload, 32).endCell();

    val extAddrBuilder = beginCell().storeUint(1, 2).storeUint(32, 9).storeUint(testPayload, 32);
    val extOutMsg = createExternalLogMessage({ dest: extAddrBuilder, body: testBody });

    val receipt = wallet.sendOwnerActions(
        owner.address,
        0,
        [
            SendMessageAction {
                sendMode: SEND_MODE_REGULAR,
                outMsg: extOutMsg.messageCell,
            },
        ],
        { value: grams("0.1") },
    );

    expect(receipt).toHaveSuccessfulTx({
        from: owner.address,
        to: wallet.address,
        exitCode: 0,
    });

    expect(receipt.findExternalOutMessage({ from: wallet.address }) != null).toBeTrue();
}
