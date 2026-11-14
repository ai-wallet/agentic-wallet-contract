import "@stdlib/exotic-cells"

import "@acton/build"
import "@acton/crypto"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/tlb/maybe"
import "@acton/types/big_array"
import "@acton/types/transaction"

import "@contracts/AgenticWallet"
import "@contracts/errors"
import "@contracts/fees"
import "@contracts/messages"
import "@contracts/storage-collection"
import "@tests/fixtures"
import "@tests/utils"
import "@wrappers/AgenticCollection.gen"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/send"
import "@wrappers/utils"
import "@tests/w5/utils"

const DESTROY_MODE = SEND_MODE_DESTROY | SEND_MODE_IGNORE_ERRORS

get fun `test wallet: owner action should fail with destroy send mode`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val receiver = randomAddress("receiver");

    val receipt = wallet.sendOwnerActions(
        owner.address,
        0,
        [sendMessageAction(receiver, 0, null, DESTROY_MODE)],
        { value: DEFAULT_MESSAGE_VALUE },
    );

    expect(receipt).toHaveFailedTx<OwnerActionRequest>({
        from: owner.address,
        to: wallet.address,
        exitCode: Errors.DestroyNotAllowed,
    });
    expect(receipt).toNotHaveTx({ to: receiver });
}

/// The wallet commits the seqno before it checks the actions, so the seqno still increments.
get fun `test wallet: signed external should fail with destroy send mode`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val receiver = randomAddress("receiver");

    val request = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(receiver, 0, null, DESTROY_MODE)],
    );
    val receipt = wallet.sendExternalSigned(request)!;

    expect(receipt).toHaveTx({ exitCode: Errors.DestroyNotAllowed });
    expect(receipt).toNotHaveTx({ from: wallet.address });
    expect(receipt).toNotHaveTx({ to: receiver });
    expect(wallet.seqno()).toEqual(1);
}

get fun `test wallet: signed internal should fail with destroy send mode`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    val receiver = randomAddress("receiver");

    val request = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(receiver, 0, null, DESTROY_MODE)],
    );
    val receipt = wallet.sendSignedRequest(
        relayer.address,
        request,
        { value: DEFAULT_MESSAGE_VALUE },
    );

    expect(receipt).toHaveFailedTx<InternalSignedRequest>({
        from: relayer.address,
        to: wallet.address,
        exitCode: Errors.DestroyNotAllowed,
    });
    expect(receipt).toNotHaveTx({ to: receiver });
    expect(wallet.seqno()).toEqual(0);
}

/// One action without ignore-errors rejects the whole list, valid actions included.
get fun `test wallet: signed external should fail if any action lacks ignore-errors`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val receiver1 = randomAddress("receiver-1");
    val receiver2 = randomAddress("receiver-2");

    val request = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            sendMessageAction(receiver1, grams("0.001")),
            sendMessageAction(receiver2, grams("0.001"), null, SEND_MODE_PAY_FEES_SEPARATELY),
        ],
    );
    val receipt = wallet.sendExternalSigned(request)!;

    expect(receipt).toHaveTx({
        exitCode: Errors.ExternalSendMessageMustHaveIgnoreErrorsSendMode,
    });
    expect(receipt).toNotHaveTx({ from: wallet.address });
    expect(receipt).toNotHaveTx({ to: receiver1 });
    expect(receipt).toNotHaveTx({ to: receiver2 });
    expect(wallet.seqno()).toEqual(1);
}

/// The validation reads the whole list. A bad first action is the deepest node, not the head.
get fun `test wallet: signed external should fail if the first of several actions lacks ignore-errors`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val receiver1 = randomAddress("receiver-1");
    val receiver2 = randomAddress("receiver-2");

    val request = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            sendMessageAction(receiver1, grams("0.001"), null, SEND_MODE_PAY_FEES_SEPARATELY),
            sendMessageAction(receiver2, grams("0.001")),
            sendMessageAction(receiver2, grams("0.001")),
        ],
    );
    val receipt = wallet.sendExternalSigned(request)!;

    expect(receipt).toHaveTx({
        exitCode: Errors.ExternalSendMessageMustHaveIgnoreErrorsSendMode,
    });
    expect(receipt).toNotHaveTx({ from: wallet.address });
    expect(receipt).toNotHaveTx({ to: receiver1 });
    expect(receipt).toNotHaveTx({ to: receiver2 });
    expect(wallet.seqno()).toEqual(1);
}

get fun `test wallet: signed internal should fail if the first of several actions uses destroy mode`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    val receiver1 = randomAddress("receiver-1");
    val receiver2 = randomAddress("receiver-2");

    val request = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            sendMessageAction(receiver1, 0, null, DESTROY_MODE),
            sendMessageAction(receiver2, grams("0.001")),
            sendMessageAction(receiver2, grams("0.001")),
        ],
    );
    val receipt = wallet.sendSignedRequest(
        relayer.address,
        request,
        { value: DEFAULT_MESSAGE_VALUE },
    );

    expect(receipt).toHaveFailedTx<InternalSignedRequest>({
        from: relayer.address,
        to: wallet.address,
        exitCode: Errors.DestroyNotAllowed,
    });
    expect(receipt).toNotHaveTx({ to: receiver1 });
    expect(receipt).toNotHaveTx({ to: receiver2 });
    expect(wallet.seqno()).toEqual(0);
}

/// Sets the highest seqno directly: 2^32 - 1 requests through transactions are not practical.
fun walletAtMaxSeqno(keyPair: KeyPair): (AgenticWallet, Treasury) {
    val (wallet, owner) = deployWalletWithKey(keyPair);
    var storage = wallet.storage();
    storage.seqno = 0xFFFFFFFF;
    wallet.setStorage(storage);
    return (wallet, owner);
}

/// The seqno increment overflows uint32 (exit 5) at the highest seqno. The external is
/// already accepted, so the seqno stays and each resend costs the wallet gas until it expires.
get fun `test wallet: signed external at the highest seqno should fail and keep the seqno`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = walletAtMaxSeqno(keyPair);
    val receiver = randomAddress("receiver");

    val request = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0xFFFFFFFF,
        [sendMessageAction(receiver, grams("0.01"))],
    );

    val balance0 = testing.getAccountBalance(wallet.address);
    val first = wallet.sendExternalSigned(request)!;
    expect(first).toHaveTx({ exitCode: 5 });
    expect(first).toNotHaveTx({ from: wallet.address });
    val balance1 = testing.getAccountBalance(wallet.address);

    val second = wallet.sendExternalSigned(request)!;
    expect(second).toHaveTx({ exitCode: 5 });

    expect(wallet.seqno()).toEqual(0xFFFFFFFF);
    expect(balance1).toBeLess(balance0);
    expect(testing.getAccountBalance(wallet.address)).toBeLess(balance1);
}

/// At the highest seqno, every seqno increment overflows: the owner can not transfer the wallet or
/// change the delegate key.
get fun `test wallet: transfer and delegate change at the highest seqno should fail`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = walletAtMaxSeqno(keyPair);
    val dataBefore = wallet.dataHash();

    val transfer = wallet.sendAny(
        owner.address,
        changeOwnerBody(randomAddress("newOwner")),
        { value: DEFAULT_MESSAGE_VALUE },
    );
    expect(transfer).toHaveFailedTx({ from: owner.address, to: wallet.address, exitCode: 5 });

    val delegate = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        0,
        { value: DEFAULT_MESSAGE_VALUE },
    );
    expect(delegate).toHaveFailedTx({ from: owner.address, to: wallet.address, exitCode: 5 });

    expect(wallet.dataHash()).toEqual(dataBefore);
}

/// An owner action does not increment the seqno. At the highest seqno, the owner can still send
/// funds from the wallet.
get fun `test wallet: owner action at the highest seqno should still send`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = walletAtMaxSeqno(keyPair);
    val receiver = randomAddress("receiver");

    val receipt = wallet.sendOwnerActions(
        owner.address,
        0,
        [sendMessageAction(receiver, grams("0.01"))],
        { value: DEFAULT_MESSAGE_VALUE },
    );

    expect(receipt).toHaveTx({ from: wallet.address, to: receiver });
    expect(wallet.seqno()).toEqual(0xFFFFFFFF);
}

/// A signed external that fails in compute still uses its seqno, so nobody can replay it.
get fun `test wallet: signed external failing in compute should not be replayable`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);

    val request = createExternalSignedRequestRaw(keyPair, wallet.address, 0, createEmptyCell());

    val first = wallet.sendExternalSigned(request);
    expect(first != null).toBeTrue();
    expect(first!).toHaveTx({ exitCode: Errors.InvalidC5 });
    expect(first!).toNotHaveTx({ from: wallet.address });
    expect(wallet.seqno()).toEqual(1);

    wallet.expectExternalRejected(request.toCell(), Errors.InvalidSeqno as int);
    expect(wallet.seqno()).toEqual(1);
}

/// A failed internal reverts its seqno, so the delegate can try the same seqno again.
get fun `test wallet: failed signed internal should keep the seqno for a retry`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    val receiver = randomAddress("receiver");

    val failing = createInternalSignedRequestRaw(keyPair, wallet.address, 0, createEmptyCell());
    val receipt1 = wallet.sendSignedRequest(
        relayer.address,
        failing,
        { value: DEFAULT_MESSAGE_VALUE },
    );
    expect(receipt1).toHaveFailedTx({ to: wallet.address, exitCode: Errors.InvalidC5 });
    expect(wallet.seqno()).toEqual(0);

    val retry = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(receiver, grams("0.001"))],
    );
    val receipt2 = wallet.sendSignedRequest(
        relayer.address,
        retry,
        { value: DEFAULT_MESSAGE_VALUE },
    );
    expect(receipt2).toHaveTx({ from: wallet.address, to: receiver });
    expect(wallet.seqno()).toEqual(1);
}

/// An internal that fails in the action phase reverts its seqno. The same signed body
/// stays valid until it expires, and anyone can send it again.
get fun `test wallet: signed internal failing in the action phase should stay replayable`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    val anyone = testing.treasury("anyone");
    val receiver = randomAddress("receiver");

    val request = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            sendMessageAction(
                receiver,
                grams("20"),
                null,
                SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
            ),
        ],
    );

    val first = wallet.sendSignedRequest(
        relayer.address,
        request,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    expect(first).toNotHaveTx({ to: receiver });
    expect(first).toHaveTx({ from: wallet.address, to: relayer.address, bounced: true });
    expect(wallet.seqno()).toEqual(0);

    wallet.sendAny(owner.address, createEmptyCell(), { value: grams("30") });

    val again = wallet.sendSignedRequest(anyone.address, request, { value: DEFAULT_MESSAGE_VALUE });
    expect(again).toHaveTx({ from: wallet.address, to: receiver });
    expect(wallet.seqno()).toEqual(1);
}

/// With ignore-errors, the wallet skips an action that it can not pay and the request uses its
/// seqno.
get fun `test wallet: signed internal with ignore-errors should use the seqno on an unpayable action`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    val receiver = randomAddress("receiver");

    val request = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(receiver, grams("20"))],
    );

    val receipt = wallet.sendSignedRequest(
        relayer.address,
        request,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    expect(receipt).toNotHaveTx({ to: receiver });
    expect(wallet.seqno()).toEqual(1);
}

/// An action list must be ordinary cells. A library cell at the root or as `prev` fails on every
/// path.
get fun `test wallet: exotic action list cell should fail on every path`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    val receiver = randomAddress("receiver");

    val validList = buildOutActions([sendMessageAction(receiver, grams("0.001"))]);
    var actionNode = validList.beginParse();
    actionNode.loadRef();
    val exoticRoot = validList.toLibraryReference();
    val exoticPrev = beginCell()
        .storeRef(validList.toLibraryReference())
        .storeSlice(actionNode)
        .endCell();
    val actionLists: array<cell> = [exoticRoot, exoticPrev];

    // the same list in an ordinary cell succeeds, so only the exotic cell causes the failures below
    val control = wallet.sendSignedRequest(
        relayer.address,
        createInternalSignedRequestRaw(keyPair, wallet.address, 0, validList),
        { value: DEFAULT_MESSAGE_VALUE },
    );
    expect(control).toHaveTx({ from: wallet.address, to: receiver });

    var seqno = 1;
    var i = 0;
    while (i < actionLists.size()) {
        val actionList = actionLists.get(i);

        val intBody = createInternalSignedRequestRaw(keyPair, wallet.address, seqno, actionList);
        val intReceipt = wallet.sendSignedRequest(
            relayer.address,
            intBody,
            { value: DEFAULT_MESSAGE_VALUE },
        );
        expect(intReceipt).toHaveFailedTx({ to: wallet.address, exitCode: Errors.InvalidC5 });

        val extBody = createExternalSignedRequestRaw(keyPair, wallet.address, seqno, actionList);
        val extReceipt = wallet.sendExternalSigned(extBody);
        if (extReceipt == null) {
            Assert.fail("External message was not accepted");
        }
        expect(extReceipt).toHaveTx({ exitCode: Errors.InvalidC5 });
        expect(extReceipt).toNotHaveTx({ from: wallet.address });
        seqno += 1;

        val ownerReceipt = wallet.sendAny(
            owner.address,
            OwnerActionRequest {
                queryId: 0,
                outActions: actionList,
            }.toCell(),
            { value: DEFAULT_MESSAGE_VALUE },
        );
        expect(ownerReceipt).toHaveFailedTx({ to: wallet.address, exitCode: Errors.InvalidC5 });

        i += 1;
    }
    expect(wallet.seqno()).toEqual(seqno);
}

/// Two wallets have the same delegate key. A request names the wallet that it is signed for.
get fun `test wallet: request signed for another wallet with the same key should fail`() {
    val keyPair = namedKeyPair("keyPair");
    val (walletA, _) = deployWalletWithKey(keyPair);
    val (walletB, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    val receiver = randomAddress("receiver");
    val actions = [sendMessageAction(receiver, grams("0.001"))];

    expect(walletA.address != walletB.address).toBeTrue();

    val internalForA = createInternalSignedRequest(keyPair, walletA.address, 0, actions);
    val receipt = walletB.sendSignedRequest(
        relayer.address,
        internalForA,
        { value: DEFAULT_MESSAGE_VALUE },
    );
    expect(receipt).toHaveFailedTx<InternalSignedRequest>({
        from: relayer.address,
        to: walletB.address,
        exitCode: Errors.InvalidWalletAddress,
    });

    val externalForA = createExternalSignedRequest(keyPair, walletA.address, 0, actions);
    walletB.expectExternalRejected(externalForA.toCell(), Errors.InvalidWalletAddress as int);
    expect(walletB.seqno()).toEqual(0);

    // the request is valid for wallet A
    expect(
        walletA.sendExternalSigned(externalForA)!,
    ).toHaveTx({ from: walletA.address, to: receiver });
}

/// `validUntil` must be later than now. The earliest valid value is now + 1.
get fun `test wallet: signed request valid until one second ahead should succeed`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    val receiver = randomAddress("receiver");
    val actions = [sendMessageAction(receiver, grams("0.001"))];

    val external = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        actions,
        blockchain.now() + 1,
    );
    expect(wallet.sendExternalSigned(external)!).toHaveTx({ from: wallet.address, to: receiver });

    val internal = createInternalSignedRequest(
        keyPair,
        wallet.address,
        1,
        actions,
        blockchain.now() + 1,
    );
    val receipt = wallet.sendSignedRequest(
        relayer.address,
        internal,
        { value: DEFAULT_MESSAGE_VALUE },
    );
    expect(receipt).toHaveTx({ from: wallet.address, to: receiver });
    expect(wallet.seqno()).toEqual(2);
}

/// A request with a full header and a valid signature, but no action list, passes the size and
/// signature checks. So it throws, and the wallet does not ignore it.
get fun `test wallet: signed internal without action list should fail after signature check`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");

    val header = beginCell()
        .storeUint(0xc369a095, 32) // InternalSignedRequest
        .storeAddress(wallet.address)
        .storeUint(blockchain.now() + 1000, 32)
        .storeUint(0, 32)
        .endCell();
    val signature = crypto.sign(keyPair.privateKey, header);
    val body = beginCell().storeSlice(header.beginParse()).storeSlice(signature).endCell();

    val receipt = wallet.sendAny(relayer.address, body, { value: DEFAULT_MESSAGE_VALUE });

    // cell underflow (9): the action list ref is missing
    expect(receipt).toHaveFailedTx({ from: relayer.address, to: wallet.address, exitCode: 9 });
    expect(wallet.seqno()).toEqual(0);
}

get fun `test wallet: signed internal to an uninitialized wallet should be ignored`() {
    val keyPair = namedKeyPair("keyPair");
    val wallet = deployUninitializedWallet(randomAddress("collection"), 0);
    val relayer = testing.treasury("relayer");
    val receiver = randomAddress("receiver");

    val request = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(receiver, grams("0.001"))],
    );
    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendSignedRequest(
        relayer.address,
        request,
        { value: DEFAULT_MESSAGE_VALUE },
    );

    expect(receipt).toHaveSuccessfulTx<InternalSignedRequest>({
        from: relayer.address,
        to: wallet.address,
        exitCode: 0,
    });
    expect(receipt).toNotHaveTx({ to: receiver });
    expect(wallet.seqno()).toEqual(0);
    wallet.expectIgnored(receipt, relayer.address, dataHashBefore);
}

get fun `test wallet: owner action to an uninitialized wallet should be ignored`() {
    val wallet = deployUninitializedWallet(randomAddress("collection"), 0);
    val sender = testing.treasury("sender");
    val receiver = randomAddress("receiver");

    val dataHashBefore = wallet.dataHash();
    val receipt = wallet.sendOwnerActions(
        sender.address,
        0,
        [sendMessageAction(receiver, grams("0.001"))],
        { value: DEFAULT_MESSAGE_VALUE },
    );

    expect(receipt).toHaveSuccessfulTx<OwnerActionRequest>({
        from: sender.address,
        to: wallet.address,
        exitCode: 0,
    });
    expect(receipt).toNotHaveTx({ to: receiver });
    wallet.expectIgnored(receipt, sender.address, dataHashBefore);
}

get fun `test wallet: signed external to an uninitialized wallet should be rejected`() {
    val keyPair = namedKeyPair("keyPair");
    val wallet = deployUninitializedWallet(randomAddress("collection"), 0);

    val request = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(randomAddress("receiver"), grams("0.001"))],
    );

    wallet.expectExternalRejected(request.toCell(), Errors.NotInitialized as int);
    expect(wallet.seqno()).toEqual(0);
}

get fun `test wallet: uninitialized wallet should report no delegate key`() {
    val wallet = deployUninitializedWallet(randomAddress("collection"), 0);

    expect(wallet.getPublicKey()).toEqual(0);
}

get fun `test wallet: non-owner should not set its own delegate key`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val stranger = testing.treasury("stranger");
    val strangerKey = namedKeyPair("strangerKey");

    val receipt = wallet.sendChangeWalletDelegate(
        stranger.address,
        0,
        strangerKey.publicKey as uint256,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(receipt).toHaveFailedTx<ChangeWalletDelegate>({
        from: stranger.address,
        to: wallet.address,
        exitCode: Errors.NotFromOwner,
    });
    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);

    val request = createExternalSignedRequest(
        strangerKey,
        wallet.address,
        0,
        [sendMessageAction(stranger.address, grams("0.001"))],
    );
    wallet.expectExternalRejected(request.toCell(), Errors.InvalidSignature as int);
    expect(wallet.seqno()).toEqual(0);
}

/// A delegate key change cancels the old key immediately. The wallet rejects requests of the old
/// key and accepts requests of the new key.
get fun `test wallet: owner key rotation should revoke the old key`() {
    val oldKey = namedKeyPair("oldKey");
    val newKey = namedKeyPair("newKey");
    val (wallet, owner) = deployWalletWithKey(oldKey);
    val receiver = randomAddress("receiver");

    wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        newKey.publicKey as uint256,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    expect(wallet.getPublicKey()).toEqual(newKey.publicKey);
    expect(wallet.seqno()).toEqual(1);

    val oldRequest = createExternalSignedRequest(
        oldKey,
        wallet.address,
        1,
        [sendMessageAction(receiver, grams("0.001"))],
    );
    wallet.expectExternalRejected(oldRequest.toCell(), Errors.InvalidSignature as int);
    expect(wallet.seqno()).toEqual(1);

    val newRequest = createExternalSignedRequest(
        newKey,
        wallet.address,
        1,
        [sendMessageAction(receiver, grams("0.001"))],
    );
    val receipt = wallet.sendExternalSigned(newRequest)!;
    expect(receipt).toHaveTx({ from: wallet.address, to: receiver });
    expect(wallet.seqno()).toEqual(2);
}

/// Each delegate key change increments the seqno. If the owner removes the key and sets it again,
/// external and internal requests signed before the change are canceled.
get fun `test wallet: delegate key change should cancel requests signed before it`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    val receiver = randomAddress("receiver");
    val actions = [sendMessageAction(receiver, grams("0.001"))];

    val oldExternal = createExternalSignedRequest(keyPair, wallet.address, 0, actions);
    val oldInternal = createInternalSignedRequest(keyPair, wallet.address, 0, actions);

    // pause: removes the key
    wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        0,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    expect(wallet.seqno()).toEqual(1);

    // resume: sets the same key again
    wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        keyPair.publicKey as uint256,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
    expect(wallet.seqno()).toEqual(2);

    wallet.expectExternalRejected(oldExternal.toCell(), Errors.InvalidSeqno as int);
    val oldReceipt = wallet.sendSignedRequest(
        relayer.address,
        oldInternal,
        { value: DEFAULT_MESSAGE_VALUE },
    );
    expect(oldReceipt).toHaveFailedTx<InternalSignedRequest>({
        from: relayer.address,
        to: wallet.address,
        exitCode: Errors.InvalidSeqno,
    });
    expect(oldReceipt).toNotHaveTx({ to: receiver });
    expect(wallet.seqno()).toEqual(2);

    val fresh = createExternalSignedRequest(keyPair, wallet.address, 2, actions);
    expect(wallet.sendExternalSigned(fresh)!).toHaveTx({ from: wallet.address, to: receiver });
    expect(wallet.seqno()).toEqual(3);
}

/// A collection with `wallet` as admin, not deployed yet.
fun collectionAdministeredBy(wallet: AgenticWallet): AgenticCollection {
    return AgenticCollection.fromStorage(
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
                deployPrice: SETUP_DEPLOY_PRICE,
                referralBps: 0,
                traitSetCount: 1,
            },
        ),
    );
}

/// Sends the collection's StateInit, deploying it.
fun deployCollectionAction(collection: AgenticCollection): SendMessageAction {
    val deployMsg = createMessage({
        bounce: false,
        value: SETUP_DEPLOY_VALUE,
        dest: { stateInit: collection.stateInit! },
    });
    return {
        sendMode: SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
        outMsg: deployMsg.messageCell,
    };
}

get fun `test wallet: signed internal should deploy a contract with init state`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    val newCollection = collectionAdministeredBy(wallet);

    val request = createInternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [deployCollectionAction(newCollection)],
    );
    val receipt = wallet.sendSignedRequest(
        relayer.address,
        request,
        { value: DEFAULT_MESSAGE_VALUE },
    );

    expect(receipt).toHaveSuccessfulDeploy({ from: wallet.address, to: newCollection.address });
    expect(newCollection.getCollectionData().adminAddress).toEqual(wallet.address);
    expect(wallet.seqno()).toEqual(1);
}

get fun `test wallet: owner action should deploy a contract with init state`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val newCollection = collectionAdministeredBy(wallet);

    val receipt = wallet.sendOwnerActions(
        owner.address,
        0,
        [deployCollectionAction(newCollection)],
        { value: DEFAULT_MESSAGE_VALUE },
    );

    expect(receipt).toHaveSuccessfulDeploy({ from: wallet.address, to: newCollection.address });
    expect(newCollection.getCollectionData().adminAddress).toEqual(wallet.address);
}

/// Only send-message actions are permitted on the owner path too.
get fun `test wallet: owner action should fail with a reserve action`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);

    val reserveAction = reserveActionList();
    val receipt = wallet.sendAny(
        owner.address,
        OwnerActionRequest {
            queryId: 0,
            outActions: reserveAction,
        }.toCell(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(receipt).toHaveFailedTx<OwnerActionRequest>({
        from: owner.address,
        to: wallet.address,
        exitCode: Errors.InvalidC5,
    });
    expect(receipt).toHaveTx({ from: wallet.address, to: owner.address });
}

/// Sends one message with `sendMode` from a new wallet through `path`: 0 signed external,
/// 1 signed internal, 2 owner action. Returns the receipt and the wallet.
fun sendWithMode(path: int, sendMode: uint8, receiver: address): (SendResultList, AgenticWallet) {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val actions = [sendMessageAction(receiver, grams("0.001"), null, sendMode)];

    if (path == 0) {
        val request = createExternalSignedRequest(keyPair, wallet.address, 0, actions);
        return (wallet.sendExternalSigned(request)!, wallet);
    }
    if (path == 1) {
        val request = createInternalSignedRequest(keyPair, wallet.address, 0, actions);
        val relayer = testing.treasury("relayer");
        return (
            wallet.sendSignedRequest(relayer.address, request, { value: DEFAULT_MESSAGE_VALUE }),
            wallet,
        );
    }
    return (
        wallet.sendOwnerActions(owner.address, 0, actions, { value: DEFAULT_MESSAGE_VALUE }),
        wallet,
    );
}

/// A send mode has 8 bits, so this test sends each possible mode on each path. It checks only the
/// validator decision: the action phase result is TON behaviour.
get fun `test wallet: action validator should decide every send mode on every path`() {
    val receiver = randomAddress("receiver");

    var mode = 0;
    while (mode < 256) {
        var path = 0;
        while (path < 3) {
            val (receipt, wallet) = sendWithMode(path, mode as uint8, receiver);
            if ((mode & SEND_MODE_DESTROY) != 0) {
                expect(receipt).toHaveTx({ exitCode: Errors.DestroyNotAllowed });
            } else if (path != 0) {
                expect(receipt).toHaveTx({ to: wallet.address, exitCode: 0 });
            } else if ((mode & SEND_MODE_IGNORE_ERRORS) == 0) {
                expect(receipt).toHaveTx({
                    exitCode: Errors.ExternalSendMessageMustHaveIgnoreErrorsSendMode,
                });
            } else {
                // a `to` filter does not match an external-in transaction
                expect(receipt).toHaveTx({ exitCode: 0 });
            }
            path += 1;
        }
        mode += 1;
    }
}

/// The wallet sends each base mode (0, +1, 64, 128). Mode 64 needs an incoming value, so
/// externals skip it.
fun expectEachModeSends(path: int, ignoreErrorsVariants: array<uint8>) {
    val baseModes: array<uint8> = [
        SEND_MODE_REGULAR,
        SEND_MODE_PAY_FEES_SEPARATELY,
        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
        SEND_MODE_CARRY_ALL_BALANCE,
    ];
    var i = 0;
    while (i < baseModes.size()) {
        val baseMode = baseModes.get(i);
        var j = 0;
        while (j < ignoreErrorsVariants.size()) {
            val sendMode = baseMode | ignoreErrorsVariants.get(j);
            if (path != 0 || baseMode != SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE) {
                val receiver = randomAddress("receiver");
                val (receipt, wallet) = sendWithMode(path, sendMode, receiver);
                expect(receipt).toHaveTx({ from: wallet.address, to: receiver });
                if (path != 2) {
                    expect(wallet.seqno()).toEqual(1);
                }
            }
            j += 1;
        }
        i += 1;
    }
}

get fun `test wallet: signed external should send with each mode plus ignore-errors`() {
    expectEachModeSends(0, [SEND_MODE_IGNORE_ERRORS]);
}

get fun `test wallet: signed internal should send with each send mode`() {
    expectEachModeSends(1, [0, SEND_MODE_IGNORE_ERRORS]);
}

get fun `test wallet: owner should send with each send mode`() {
    expectEachModeSends(2, [0, SEND_MODE_IGNORE_ERRORS]);
}

get fun `test wallet: signed external should fail without ignore-errors for modes 0 and 128`() {
    val sendModes: array<uint8> = [SEND_MODE_REGULAR, SEND_MODE_CARRY_ALL_BALANCE];
    var i = 0;
    while (i < sendModes.size()) {
        val receiver = randomAddress("receiver");
        val (receipt, wallet) = sendWithMode(0, sendModes.get(i), receiver);
        expect(receipt).toHaveTx({
            exitCode: Errors.ExternalSendMessageMustHaveIgnoreErrorsSendMode,
        });
        expect(receipt).toNotHaveTx({ from: wallet.address });
        expect(receipt).toNotHaveTx({ to: receiver });
        expect(wallet.seqno()).toEqual(1);
        i += 1;
    }
}

/// Mode 128 without destroy (+32) sends the full balance but keeps the account and the wallet.
get fun `test wallet: owner mode 128 should drain the balance but keep the wallet`() {
    val receiver = randomAddress("receiver");
    val (receipt, wallet) = sendWithMode(2, SEND_MODE_CARRY_ALL_BALANCE, receiver);

    expect(receipt).toHaveTx({ from: wallet.address, to: receiver });
    expect(testing.getAccountBalance(wallet.address)).toEqual(0);
    expect(testing.isDeployed(wallet.address)).toBeTrue();
    expect(wallet.getNftData().isInitialized).toBeTrue();
}

get fun `test wallet: signed external should send to a masterchain address`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val basechainReceiver = randomAddress("receiver");
    val masterchainReceiver = randomAddress("mc-receiver", -1);

    val request = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            sendMessageAction(basechainReceiver, grams("0.001")),
            sendMessageAction(masterchainReceiver, grams("0.001")),
        ],
    );
    val receipt = wallet.sendExternalSigned(request)!;

    expect(receipt).toHaveTx({ from: wallet.address, to: basechainReceiver });
    expect(receipt).toHaveTx({ from: wallet.address, to: masterchainReceiver });
    expect(wallet.seqno()).toEqual(1);
}

/// The wallet rejects an external with a valid signature but a different opcode before it
/// accepts the message. Then the same request with the correct opcode succeeds.
get fun `test wallet: external with another opcode should be rejected`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val receiver = randomAddress("receiver");
    val request = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(receiver, grams("0.001"))],
    );

    val prefixes: array<uint32> = [0x7f97334d, 0xc7966b87, 0xc369a095, 0xdeadbeef];
    var i = 0;
    while (i < prefixes.size()) {
        var tail = request.toCell().beginParse();
        tail.skipBits(32);
        val body = beginCell()
            .storeUint(prefixes.get(i), 32)
            .storeSlice(tail.removeLastBits(SIZE_SIGNATURE))
            .storeUint(0, 256)
            .storeUint(0, 256)
            .endCell();
        wallet.expectExternalRejected(
            withDelegateSignature(keyPair, body),
            Errors.InvalidMessageOperation as int,
        );
        expect(wallet.seqno()).toEqual(0);
        i += 1;
    }

    expect(wallet.sendExternalSigned(request)!).toHaveTx({ from: wallet.address, to: receiver });
    expect(wallet.seqno()).toEqual(1);
}

get fun `test wallet: uninitialized wallet should reject a delegate key change`() {
    val wallet = deployUninitializedWallet(randomAddress("collection"), 0);
    val sender = testing.treasury("sender");

    val receipt = wallet.sendChangeWalletDelegate(
        sender.address,
        0,
        namedKeyPair("newDelegate").publicKey as uint256,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(receipt).toHaveFailedTx<ChangeWalletDelegate>({
        from: sender.address,
        to: wallet.address,
        exitCode: Errors.NotInitialized,
    });
    expect(wallet.getPublicKey()).toEqual(0);
}

/// A bounceable message to a missing account bounces back to the wallet. The wallet accepts it
/// without effect and does not run the bounced copy of a wallet opcode as that opcode.
get fun `test wallet: signed external bounced transfer should be accepted without effect`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val missing = randomAddress("missing");
    val before = wallet.getNftData();

    val bounceable = createMessage({
        bounce: true,
        value: DEFAULT_MESSAGE_VALUE,
        dest: missing,
        body: changeOwnerBody(randomAddress("attacker")),
    });
    val request = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [
            SendMessageAction {
                sendMode: SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
                outMsg: bounceable.messageCell,
            },
        ],
    );
    val receipt = wallet.sendExternalSigned(request)!;

    expect(receipt).toHaveTx({ from: wallet.address, to: missing, success: false });
    expect(receipt).toHaveTx({ from: missing, to: wallet.address, bounced: true, success: true });
    expect(receipt.size()).toEqual(3);
    expect(wallet.getNftData()).toEqual(before);
    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);
    expect(wallet.seqno()).toEqual(1);
}

/// The wallet parses the whole envelope before it accepts the message. It rejects a signed
/// external with no action list, an extra root ref or extra bits, and pays no gas.
get fun `test wallet: signed external with a malformed envelope should be rejected before accept`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val receiver = randomAddress("receiver");
    val request = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(receiver, grams("0.001"))],
    );
    // the request fields before the action list: its bits without the trailing signature
    val requestBits = request.toCell().beginParse();
    val header = requestBits.getFirstBits(requestBits.remainingBitsCount() - SIZE_SIGNATURE);

    val bodies: array<cell> = [
        beginCell().storeSlice(header).storeUint(0, 256).storeUint(0, 256).endCell(),
        beginCell()
            .storeSlice(header)
            .storeRef(request.outActions)
            .storeRef(createEmptyCell())
            .storeUint(0, 256)
            .storeUint(0, 256)
            .endCell(),
        beginCell()
            .storeSlice(header)
            .storeRef(request.outActions)
            .storeUint(0, 8)
            .storeUint(0, 256)
            .storeUint(0, 256)
            .endCell(),
    ];
    var i = 0;
    while (i < bodies.size()) {
        wallet.expectExternalRejected(withDelegateSignature(keyPair, bodies.get(i)), 9);
        expect(wallet.seqno()).toEqual(0);
        i += 1;
    }

    expect(wallet.sendExternalSigned(request)!).toHaveTx({ from: wallet.address, to: receiver });
    expect(wallet.seqno()).toEqual(1);
}

/// A wallet with no balance can not pay for gas, so it does not accept a valid external. The seqno
/// stays usable, and the same request succeeds after a top-up.
get fun `test wallet: signed external to a drained wallet should not be accepted until topped up`() {
    val (_, wallet) = sendWithMode(2, SEND_MODE_CARRY_ALL_BALANCE, randomAddress("drain"));
    expect(testing.getAccountBalance(wallet.address)).toEqual(0);
    val receiver = randomAddress("receiver");
    val request = createExternalSignedRequest(
        namedKeyPair("keyPair"),
        wallet.address,
        0,
        [sendMessageAction(receiver, grams("0.001"))],
    );

    expect(wallet.sendAnyExternal(request.toCell())).toBeNotAccepted();
    expect(wallet.seqno()).toEqual(0);

    val funder = testing.treasury("funder");
    expect(
        wallet.sendAny(funder.address, createEmptyCell(), { value: grams("1") }),
    ).toHaveSuccessfulTx({
        from: funder.address,
        to: wallet.address,
    });

    expect(wallet.sendExternalSigned(request)!).toHaveTx({ from: wallet.address, to: receiver });
    expect(wallet.seqno()).toEqual(1);
}

/// With ignore-errors (+2), the wallet skips an action without funds and sends the other actions.
/// The request still uses its seqno.
get fun `test wallet: signed external should skip an unfundable action and still consume the seqno`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, _) = deployWalletWithKey(keyPair);
    val unfunded = randomAddress("unfunded");
    val receiver = randomAddress("receiver");

    val request = createExternalSignedRequest(
        keyPair,
        wallet.address,
        0,
        [sendMessageAction(unfunded, grams("1000")), sendMessageAction(receiver, grams("0.001"))],
    );
    val receipt = wallet.sendExternalSigned(request)!;

    // no matcher filter selects an external-in transaction, so the test checks the trace root.
    // The action phase succeeds and skips the action without funds.
    val description = receipt.at(0).tx.load().description.load();
    if (description !is TlbTransOrd) {
        Assert.fail("Expected an ordinary transaction");
    }
    expect(description.aborted).toBeFalse();
    val actionPhase = description.action.unwrap().load();
    expect(actionPhase.success).toBeTrue();
    expect(actionPhase.totActions).toEqual(2);
    expect(actionPhase.skippedActions).toEqual(1);
    expect(receipt).toNotHaveTx({ to: unfunded });
    expect(receipt).toHaveTx({ from: wallet.address, to: receiver });
    expect(wallet.seqno()).toEqual(1);

    wallet.expectExternalRejected(request.toCell(), Errors.InvalidSeqno as int);
}

/// Replaces the trailing placeholder signature of `body` with the delegate signature.
fun withDelegateSignature(keyPair: KeyPair, body: cell): cell {
    val signature = signRequest(keyPair, body);
    var unsigned = body.beginParse();
    unsigned.removeLastBits(SIZE_SIGNATURE);
    return beginCell().storeSlice(unsigned).storeSlice(signature as slice).endCell();
}

/// The script message value pays each owner and delegate request for a script-sized comment.
get fun `test script defaults: DEFAULT_MESSAGE_VALUE should cover owner and delegate requests`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, owner) = deployWalletWithKey(keyPair);
    val relayer = testing.treasury("relayer");
    val receiver = randomAddress("receiver");
    val comment = commentBody(SCRIPT_SIZED_TEXT)!;

    val request = createInternalSignedRequest(
        keyPair,
        wallet.address,
        wallet.seqno(),
        [sendMessageAction(receiver, DEFAULT_TRANSFER_AMOUNT, comment)],
    );
    val signed = wallet.sendSignedRequest(
        relayer.address,
        request,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    expect(signed).toHaveTx({ from: wallet.address, to: receiver });

    val action = wallet.sendOwnerActions(
        owner.address,
        0,
        [sendMessageAction(receiver, DEFAULT_TRANSFER_AMOUNT, comment)],
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    expect(action).toHaveTx({ from: wallet.address, to: receiver });

    val delegate = wallet.sendChangeWalletDelegate(
        owner.address,
        0,
        1,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    expect(
        delegate,
    ).toHaveSuccessfulTx<ChangeWalletDelegate>({ from: owner.address, to: wallet.address });

    val newOwner = randomAddress("newOwner");
    val transfer = wallet.sendChangeWalletOwnerPayloadAuto(
        owner.address,
        0,
        newOwner,
        owner.address,
        null,
        MIN_FORWARD_AMOUNT,
        comment.beginParse(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    expect(transfer).toHaveTx<NotificationForNewOwner>({ from: wallet.address, to: newOwner });
    expect(transfer).toHaveTx<ReturnExcessesBack>({ from: wallet.address, to: owner.address });
}
