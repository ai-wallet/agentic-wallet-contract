import "@stdlib/gas-payments"

import "@acton/build"
import "@acton/emulation/config"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/tlb/either"
import "@acton/tlb/maybe"
import "@acton/types/big_array"
import "@acton/types/message"
import "@acton/types/transaction"

import "@contracts/errors"
import "@contracts/fees"
import "@contracts/messages"
import "@contracts/storage-wallet"
import "@tests/fixtures"
import "@tests/utils"
import "@wrappers/AgenticCollection.gen"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/send"
import "@wrappers/utils"
import "@tests/w5/utils"

const DELEGATE_PUBLIC_KEY = 0x1234

/// Deploys the next wallet with the given init params. Returns the result and the wallet.
fun mintWallet(
    collection: AgenticCollection,
    admin: Treasury,
    initParams: AgenticWalletInitParams,
    attachAmount: coins = DEFAULT_WALLET_ATTACH_AMOUNT,
): (SendResultList, AgenticWallet) {
    val walletIndex = collection.getCollectionData().nextWalletIndex;
    val result = deployWallet(
        collection,
        admin.address,
        null,
        initParams,
        attachAmount,
        attachAmount + DEFAULT_DEPLOY_MESSAGE_VALUE - DEFAULT_WALLET_ATTACH_AMOUNT,
    );
    return (result, AgenticWallet.fromAddress(collection.getNftAddressByIndex(walletIndex)));
}

/// Transfers the wallet to `newOwnerAddress` with an excess recipient and `forwardAmount` in the
/// notification. Sends `value` with the request.
fun transferWithExcesses(
    wallet: AgenticWallet,
    owner: Treasury,
    newOwnerAddress: address,
    excessesAddress: address,
    forwardAmount: coins,
    value: coins,
): SendResultList {
    return wallet.sendChangeWalletOwnerPayloadInline(
        owner.address,
        0,
        newOwnerAddress,
        excessesAddress,
        null,
        forwardAmount,
        createEmptySlice(),
        { value, bounce: true },
    );
}

/// Same as `transferWithExcesses`, with an inline forward payload.
fun transferWithExcessesAndPayload(
    wallet: AgenticWallet,
    owner: Treasury,
    newOwnerAddress: address,
    excessesAddress: address,
    forwardAmount: coins,
    forwardPayload: slice,
    value: coins,
): SendResultList {
    return wallet.sendChangeWalletOwnerPayloadInline(
        owner.address,
        0,
        newOwnerAddress,
        excessesAddress,
        null,
        forwardAmount,
        forwardPayload,
        { value, bounce: true },
    );
}

get fun `test wallet nft: deploy should notify the owner`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val queryId = 42;
    val forwardAmount = grams("0.01");
    val forwardPayload = beginCell().storeUint(0xDEADBEEF, 32).toSlice();
    val walletAddress = collection.getNftAddressByIndex(0);

    val result = collection.sendRelayDeployWallet(
        admin.address,
        queryId,
        null,
        DEFAULT_WALLET_ATTACH_AMOUNT + forwardAmount,
        AgenticWalletInitParams.create(
            owner.address,
            createEmptyCell(),
            0,
            forwardAmount,
            PayloadInline { value: forwardPayload },
        ),
        { value: DEFAULT_DEPLOY_MESSAGE_VALUE + forwardAmount, bounce: true },
    );

    expect(result).toHaveSuccessfulDeploy({ from: collection.address, to: walletAddress });
    expect(result).toHaveTx<NotificationForNewOwner>({
        from: walletAddress,
        to: owner.address,
        value: forwardAmount,
        bounce: false,
        body: NotificationForNewOwner {
            queryId,
            oldOwnerAddress: collection.address,
            forwardPayload: PayloadInline { value: forwardPayload }.toCell().beginParse(),
        }.toCell(),
    });
}

/// TEP-62 permits the forward payload in a ref. The deploy forwards it without changes.
get fun `test wallet nft: deploy should notify the owner with the payload in a ref`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val queryId = 42;
    val forwardAmount = grams("0.01");
    val payloadCell = beginCell().storeUint(0xDEADBEEF, 32).endCell();
    val walletAddress = collection.getNftAddressByIndex(0);

    val result = collection.sendRelayDeployWallet(
        admin.address,
        queryId,
        null,
        DEFAULT_WALLET_ATTACH_AMOUNT + forwardAmount,
        AgenticWalletInitParams.create(
            owner.address,
            createEmptyCell(),
            0,
            forwardAmount,
            PayloadInRef { value: payloadCell as Cell<RemainingBitsAndRefs> },
        ),
        { value: DEFAULT_DEPLOY_MESSAGE_VALUE + forwardAmount, bounce: true },
    );

    expect(result).toHaveSuccessfulDeploy({ from: collection.address, to: walletAddress });
    expect(result).toHaveTx<NotificationForNewOwner>({
        from: walletAddress,
        to: owner.address,
        value: forwardAmount,
        bounce: false,
        body: NotificationForNewOwner {
            queryId,
            oldOwnerAddress: collection.address,
            forwardPayload: PayloadInRef { value: payloadCell as Cell<RemainingBitsAndRefs> }
            .toCell()
            .beginParse(),
        }.toCell(),
    });
}

get fun `test wallet nft: second deploy should not overwrite the wallet`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val wallet = nftFixture(collection, owner.address);
    val before = wallet.getNftData();

    val result = deployWallet(
        collection,
        admin.address,
        0,
        walletInitParams(admin.address, beginCell().storeString("overwrite").endCell()),
    );

    expect(result).toHaveFailedTx<DeployWallet>({
        from: collection.address,
        to: wallet.address,
        exitCode: Errors.AlreadyInitialized,
    });
    expect(wallet.getNftData()).toEqual(before);
}

get fun `test wallet nft: deploy should fail with a malformed Either forward payload`() {
    val (collection, admin, _) = setupTest();
    // Either bit 1 (ref) followed by extra bits: malformed in TEP-62
    val initParams: AgenticWalletInitParams = {
        ownerAddress: admin.address,
        content: createEmptyCell(),
        delegatePublicKey: 0,
        forwardAmount: 0,
        forwardPayload: beginCell()
            .storeBool(true)
            .storeUint(0xDEAD, 16)
            .storeRef(createEmptyCell())
            .toSlice(),
    };

    val (result, wallet) = mintWallet(collection, admin, initParams);

    expect(result).toHaveFailedTx<DeployWallet>({
        from: collection.address,
        to: wallet.address,
        exitCode: Errors.IncorrectForwardPayload,
    });
    expect(wallet.getNftData().isInitialized).toBeFalse();
}

/// Only public deploys check the owner workchain. For admin deploys, the admin is responsible.
/// A masterchain owner can still move the wallet to the basechain.
get fun `test wallet nft: admin deploy should not check the owner workchain`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner", MASTERCHAIN);
    val newOwnerAddress = randomAddress("new-owner");

    val (result, wallet) = mintWallet(
        collection,
        admin,
        walletInitParams(owner.address, createEmptyCell()),
    );

    expect(result).toHaveSuccessfulTx<DeployWallet>({
        from: collection.address,
        to: wallet.address,
    });
    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);

    val transfer = wallet.sendChangeWalletOwnerPayloadInline(
        owner.address,
        0,
        newOwnerAddress,
        null,
        null,
        0,
        createEmptySlice(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(
        transfer,
    ).toHaveSuccessfulTx<ChangeWalletOwner>({ from: owner.address, to: wallet.address });
    expect(wallet.getNftData().ownerAddress!).toEqual(newOwnerAddress);
}

get fun `test wallet nft: deploy should fail when attached value can't cover forward amount`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");

    val (result, wallet) = mintWallet(
        collection,
        admin,
        AgenticWalletInitParams.create(
            owner.address,
            createEmptyCell(),
            0,
            grams("0.05"),
            emptyForwardPayload(),
        ),
        grams("0.05"),
    );

    expect(result).toHaveFailedTx<DeployWallet>({
        from: collection.address,
        to: wallet.address,
        exitCode: Errors.TooSmallRestAmount,
    });
    expect(result).toNotHaveTx<NotificationForNewOwner>({ to: owner.address });
    expect(wallet.getNftData().isInitialized).toBeFalse();
}

get fun `test wallet nft: deploy should require the storage reserve`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    // checks the reserve value here: all other tests read it from the contract
    expect(MIN_WALLET_STORAGE).toEqual(grams("0.01"));

    val (short, shortWallet) = mintWallet(
        collection,
        admin,
        walletInitParams(owner.address, createEmptyCell()),
        MIN_WALLET_STORAGE - 1,
    );
    expect(short).toHaveFailedTx<DeployWallet>({
        from: collection.address,
        to: shortWallet.address,
        exitCode: Errors.TooSmallRestAmount,
    });
    expect(shortWallet.getNftData().isInitialized).toBeFalse();

    val (exact, wallet) = mintWallet(
        collection,
        admin,
        walletInitParams(owner.address, createEmptyCell()),
        MIN_WALLET_STORAGE,
    );
    expect(
        exact,
    ).toHaveSuccessfulTx<DeployWallet>({ from: collection.address, to: wallet.address });
    expect(exact).toNotHaveTx({ from: wallet.address });
    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
}

get fun `test wallet nft: deploy should require storage reserve, forward amount and forward fee`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val forwardAmount = grams("0.05");
    val initParams = AgenticWalletInitParams.create(
        owner.address,
        createEmptyCell(),
        0,
        forwardAmount,
        emptyForwardPayload(),
    );

    // without the forward fee, the rest amount is short by exactly that fee
    val (withoutFee, firstWallet) = mintWallet(
        collection,
        admin,
        initParams,
        MIN_WALLET_STORAGE + forwardAmount,
    );
    expect(withoutFee).toHaveFailedTx<DeployWallet>({
        from: collection.address,
        to: firstWallet.address,
        exitCode: Errors.TooSmallRestAmount,
    });
    val fwdFee = originalForwardFee(withoutFee, { to: firstWallet.address });
    val exactAmount = MIN_WALLET_STORAGE + forwardAmount + fwdFee;

    val (oneLess, secondWallet) = mintWallet(collection, admin, initParams, exactAmount - 1);
    expect(originalForwardFee(oneLess, { to: secondWallet.address })).toEqual(fwdFee);
    expect(oneLess).toHaveFailedTx<DeployWallet>({
        from: collection.address,
        to: secondWallet.address,
        exitCode: Errors.TooSmallRestAmount,
    });
    expect(oneLess).toNotHaveTx<NotificationForNewOwner>({ to: owner.address });

    val (exact, wallet) = mintWallet(collection, admin, initParams, exactAmount);
    expect(originalForwardFee(exact, { to: wallet.address })).toEqual(fwdFee);
    expect(exact).toHaveTx<NotificationForNewOwner>({
        from: wallet.address,
        to: owner.address,
        value: forwardAmount,
    });
}

get fun `test wallet nft: transfer should revoke the delegate key`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val newOwnerAddress = randomAddress("newOwnerAddress");
    val (_, wallet) = mintWallet(
        collection,
        admin,
        walletInitParams(owner.address, createEmptyCell(), DELEGATE_PUBLIC_KEY),
    );
    expect(wallet.getPublicKey()).toEqual(DELEGATE_PUBLIC_KEY);

    val result = wallet.sendChangeWalletOwnerPayloadInline(
        owner.address,
        0,
        newOwnerAddress,
        null,
        null,
        0,
        createEmptySlice(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(
        result,
    ).toHaveSuccessfulTx<ChangeWalletOwner>({ from: owner.address, to: wallet.address });
    expect(wallet.getNftData().ownerAddress!).toEqual(newOwnerAddress);
    expect(wallet.getPublicKey()).toEqual(0);
}

get fun `test wallet nft: transfer to the current owner should revoke the delegate key`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val (_, wallet) = mintWallet(
        collection,
        admin,
        walletInitParams(owner.address, createEmptyCell(), DELEGATE_PUBLIC_KEY),
    );
    expect(wallet.getPublicKey()).toEqual(DELEGATE_PUBLIC_KEY);

    val result = wallet.sendChangeWalletOwnerPayloadInline(
        owner.address,
        0,
        owner.address,
        null,
        null,
        0,
        createEmptySlice(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(
        result,
    ).toHaveSuccessfulTx<ChangeWalletOwner>({ from: owner.address, to: wallet.address });
    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
    expect(wallet.getPublicKey()).toEqual(0);
}

/// A wallet transfer removes the delegate key. The old delegate and the old owner lose access,
/// and the new owner gets control.
get fun `test wallet nft: wallet transfer should hand over control`() {
    val oldDelegate = namedKeyPair("oldDelegate");
    val (wallet, oldOwner) = deployWalletWithKey(oldDelegate);
    val newOwner = testing.treasury("new-owner");
    val receiver = randomAddress("receiver");
    val actions = [sendMessageAction(receiver, grams("0.001"))];

    val transfer = wallet.sendChangeWalletOwnerPayloadInline(
        oldOwner.address,
        0,
        newOwner.address,
        null,
        null,
        0,
        beginCell().storeBool(false).endCell().beginParse(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    expect(transfer.size()).toEqual(1);
    expect(transfer).toHaveSuccessfulTx<ChangeWalletOwner>({
        from: oldOwner.address,
        to: wallet.address,
    });
    expect(wallet.getNftData().ownerAddress!).toEqual(newOwner.address);
    expect(wallet.getPublicKey()).toEqual(0);
    expect(wallet.seqno()).toEqual(1);

    val oldRequest = createExternalSignedRequest(oldDelegate, wallet.address, 1, actions);
    wallet.expectExternalRejected(oldRequest.toCell(), Errors.InvalidSignature as int);

    val dataHashBefore = wallet.dataHash();
    val oldOwnerReceipt = wallet.sendOwnerActions(
        oldOwner.address,
        0,
        actions,
        { value: DEFAULT_MESSAGE_VALUE },
    );
    wallet.expectIgnored(oldOwnerReceipt, oldOwner.address, dataHashBefore);

    val newOwnerReceipt = wallet.sendOwnerActions(
        newOwner.address,
        0,
        actions,
        { value: DEFAULT_MESSAGE_VALUE },
    );
    expect(newOwnerReceipt).toHaveTx({ from: wallet.address, to: receiver });

    val newDelegate = namedKeyPair("newDelegate");
    wallet.sendChangeWalletDelegate(
        newOwner.address,
        0,
        newDelegate.publicKey as uint256,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    expect(wallet.seqno()).toEqual(2);
    val newRequest = createExternalSignedRequest(newDelegate, wallet.address, 2, actions);
    expect(wallet.sendExternalSigned(newRequest)!).toHaveTx({ from: wallet.address, to: receiver });
    expect(wallet.seqno()).toEqual(3);
}

/// A wallet transfer increments the seqno. Requests signed for the previous owner stay canceled,
/// even when the new owner sets the same delegate key. A rejected transfer keeps the seqno.
get fun `test wallet nft: transfer should cancel requests signed before it`() {
    val keyPair = namedKeyPair("keyPair");
    val (wallet, oldOwner) = deployWalletWithKey(keyPair);
    val newOwner = testing.treasury("new-owner");
    val relayer = testing.treasury("relayer");
    val receiver = randomAddress("receiver");
    val actions = [sendMessageAction(receiver, grams("0.001"))];

    val oldExternal = createExternalSignedRequest(keyPair, wallet.address, 0, actions);
    val oldInternal = createInternalSignedRequest(keyPair, wallet.address, 0, actions);

    val rejected = wallet.sendChangeWalletOwnerPayloadInline(
        newOwner.address,
        0,
        newOwner.address,
        null,
        null,
        0,
        createEmptySlice(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    expect(rejected).toHaveFailedTx<ChangeWalletOwner>({
        from: newOwner.address,
        to: wallet.address,
        exitCode: Errors.NotFromOwner,
    });
    expect(wallet.seqno()).toEqual(0);

    wallet.sendChangeWalletOwnerPayloadInline(
        oldOwner.address,
        0,
        newOwner.address,
        null,
        null,
        0,
        createEmptySlice(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    expect(wallet.getNftData().ownerAddress!).toEqual(newOwner.address);
    expect(wallet.seqno()).toEqual(1);

    // the new owner sets the same delegate key
    wallet.sendChangeWalletDelegate(
        newOwner.address,
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
}

get fun `test wallet nft: transfer should fail when value can't cover forward amount`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("owner");
    val wallet = nftFixture(collection, owner.address);
    val forwardAmount = grams("0.01");
    // the wallet keeps more than the storage reserve, so the rest amount check passes
    // and only the incoming value is short
    expect(testing.getAccountBalance(wallet.address)).toBeGreater(MIN_WALLET_STORAGE);

    val result = wallet.sendChangeWalletOwnerPayloadInline(
        owner.address,
        0,
        randomAddress("newOwnerAddress"),
        null,
        null,
        forwardAmount,
        createEmptySlice(),
        { value: forwardAmount, bounce: true },
    );

    expect(result).toHaveFailedTx<ChangeWalletOwner>({
        from: owner.address,
        to: wallet.address,
        exitCode: Errors.TooSmallFunding,
    });
    expect(result).toNotHaveTx<NotificationForNewOwner>({ from: wallet.address });
    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
}

get fun `test wallet nft: transfer with excesses should require forward amount and two forward fees`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("owner");
    val wallet = nftFixture(collection, owner.address);
    val newOwnerAddress = randomAddress("newOwnerAddress");
    val excessesAddress = randomAddress("excessesAddress");
    val forwardAmount = grams("0.01");
    // the wallet keeps more than the storage reserve, so the incoming value, not the rest
    // amount, limits the request
    expect(testing.getAccountBalance(wallet.address)).toBeGreater(MIN_WALLET_STORAGE);

    // without the forward fees, the request is short by exactly two fees
    val withoutFees = transferWithExcesses(
        wallet,
        owner,
        newOwnerAddress,
        excessesAddress,
        forwardAmount,
        forwardAmount,
    );
    expect(withoutFees).toHaveFailedTx<ChangeWalletOwner>({
        from: owner.address,
        to: wallet.address,
        exitCode: Errors.TooSmallFunding,
    });
    val fwdFee = originalForwardFee(withoutFees, { from: owner.address, to: wallet.address });
    val exactValue = forwardAmount + fwdFee * 2;

    val oneLess = transferWithExcesses(
        wallet,
        owner,
        newOwnerAddress,
        excessesAddress,
        forwardAmount,
        exactValue - 1,
    );
    expect(
        originalForwardFee(oneLess, { from: owner.address, to: wallet.address }),
    ).toEqual(fwdFee);
    expect(oneLess).toHaveFailedTx<ChangeWalletOwner>({
        from: owner.address,
        to: wallet.address,
        exitCode: Errors.TooSmallFunding,
    });

    val exact = transferWithExcesses(
        wallet,
        owner,
        newOwnerAddress,
        excessesAddress,
        forwardAmount,
        exactValue,
    );
    expect(
        originalForwardFee(exact, { from: owner.address, to: wallet.address }),
    ).toEqual(fwdFee);
    expect(
        exact,
    ).toHaveSuccessfulTx<ChangeWalletOwner>({ from: owner.address, to: wallet.address });
    expect(exact).toHaveTx<NotificationForNewOwner>({
        from: wallet.address,
        to: newOwnerAddress,
        value: forwardAmount,
    });
    // the request pays only the forward amount and fees, so there is nothing to return
    expect(exact).toHaveTx<ReturnExcessesBack>({
        from: wallet.address,
        to: excessesAddress,
        value: 0,
    });
    expect(wallet.getNftData().ownerAddress!).toEqual(newOwnerAddress);
}

/// Sends a `ChangeWalletOwner` body built inline in the message.
fun sendInlineTransfer(from: address, dest: address, body: slice, value: coins): SendResultList {
    val message = TlbMessageRelaxed<RemainingBitsAndRefs> {
        info: TlbIntMsgInfoRelaxed {
            ihrDisabled: true,
            bounce: true,
            bounced: false,
            src: createAddressNone(),
            dest,
            value: { grams: value, other: [] },
            extraFlags: 0,
            fwdFee: 0,
            createdLt: 0,
            createdAt: 0,
        },
        init: TlbMaybe.none(),
        body: TlbEither<RemainingBitsAndRefs, Cell<RemainingBitsAndRefs>>.left(body),
    };
    return net.send(from, OutMessage { messageCell: message.toCell() });
}

get fun `test wallet nft: transfer at the minimum value should cost the wallet only gas`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("owner");
    val wallet = nftFixture(collection, owner.address);
    val newOwnerAddress = randomAddress("newOwnerAddress");
    val forwardAmount = grams("0.01");
    // the body can not fit next to the full message header. The action phase of the sender moves
    // it to a ref: 32 + 64 + 267 + 2 + 1 + 28 + 1 bits in one cell.
    val fwdFee = calculateForwardFee(BASECHAIN, 395, 1);
    val body = beginCell()
        .storeUint(0x5fcc3d14, 32) // op::transfer
        .storeUint(0, 64) // queryId
        .storeAddress(newOwnerAddress) // new_owner
        .storeAddressNone() // response_destination
        .storeMaybeRef(null) // custom_payload
        .storeCoins(forwardAmount) // forward_amount
        .storeBool(false) // forward_payload: inline, empty
        .toSlice();
    val balanceBefore = testing.getAccountBalance(wallet.address);

    val result = sendInlineTransfer(owner.address, wallet.address, body, forwardAmount + fwdFee);

    expect(
        originalForwardFee(result, { from: owner.address, to: wallet.address }),
    ).toEqual(fwdFee);
    expect(
        result,
    ).toHaveSuccessfulTx<ChangeWalletOwner>({ from: owner.address, to: wallet.address });
    expect(result).toHaveTx<NotificationForNewOwner>({
        from: wallet.address,
        to: newOwnerAddress,
        value: forwardAmount,
    });
    expect(wallet.getNftData().ownerAddress!).toEqual(newOwnerAddress);
    // the request paid enough for the forward fee of the notification
    val walletTx = result.findTransaction({ from: owner.address, to: wallet.address })!;
    expect(
        balanceBefore - testing.getAccountBalance(wallet.address),
    ).toBeLessOrEqual(gasAndStorageFees(walletTx));
}

get fun `test wallet nft: transfer with a large inline payload and excesses should cost the wallet only gas`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("owner");
    val wallet = nftFixture(collection, owner.address);
    val newOwnerAddress = randomAddress("newOwnerAddress");
    val excessesAddress = randomAddress("excessesAddress");
    val forwardAmount = grams("0.01");
    // fills the transfer body almost to the cell limit, more than a notification can inline
    val payloadBits = beginCell().storeUint(0xDEADBEEF, 200).storeUint(0, 150);
    val balanceBefore = testing.getAccountBalance(wallet.address);

    val result = transferWithExcessesAndPayload(
        wallet,
        owner,
        newOwnerAddress,
        excessesAddress,
        forwardAmount,
        payloadBits.toSlice(),
        DEFAULT_MESSAGE_VALUE + forwardAmount,
    );

    expect(
        result,
    ).toHaveSuccessfulTx<ChangeWalletOwner>({ from: owner.address, to: wallet.address });
    expect(result).toHaveTx<NotificationForNewOwner>({
        from: wallet.address,
        to: newOwnerAddress,
        value: forwardAmount,
        body: NotificationForNewOwner {
            queryId: 0,
            oldOwnerAddress: owner.address,
            forwardPayload: beginCell().storeBool(false).storeBuilder(payloadBits).toSlice(),
        }.toCell(),
    });
    expect(result).toHaveTx<ReturnExcessesBack>({ from: wallet.address, to: excessesAddress });
    expect(wallet.getNftData().ownerAddress!).toEqual(newOwnerAddress);
    val walletTx = result.findTransaction({ from: owner.address, to: wallet.address })!;
    expect(
        balanceBefore - testing.getAccountBalance(wallet.address),
    ).toBeLessOrEqual(gasAndStorageFees(walletTx));
}

get fun `test wallet nft: uninitialized wallet should reject transfer`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("owner");
    val walletIndex = collection.getCollectionData().nextWalletIndex;
    val wallet = deployUninitializedWallet(collection.address, walletIndex as uint64);

    val result = wallet.sendChangeWalletOwnerPayloadInline(
        owner.address,
        0,
        randomAddress("newOwnerAddress"),
        null,
        null,
        0,
        createEmptySlice(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveFailedTx<ChangeWalletOwner>({
        from: owner.address,
        to: wallet.address,
        exitCode: Errors.NotInitialized,
    });
    expect(wallet.getNftData().isInitialized).toBeFalse();
}

/// The owner makes the collection bounce a content edit back to the wallet. The bounce comes from
/// the collection, but the wallet must not apply it as a content edit.
get fun `test wallet nft: content edit bounced by the collection should not change the content`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("owner");
    val wallet = nftFixture(collection, owner.address);
    val dataBefore = wallet.dataHash();

    val forged = beginCell().storeUint(0xBEEF, 16).endCell();
    val outMsg = createMessage({
        bounce: true,
        value: grams("0.1"),
        dest: collection.address,
        body: EditWalletContent {
            queryId: 7,
            newContent: forged,
        },
    });
    val result = wallet.sendOwnerActions(
        owner.address,
        0,
        [{ sendMode: SEND_MODE_PAY_FEES_SEPARATELY, outMsg: outMsg.messageCell }],
        { value: grams("0.5") },
    );

    expect(
        result,
    ).toHaveFailedTx({ from: wallet.address, to: collection.address, exitCode: 0xFFFF });
    expect(result).toHaveSuccessfulTx({
        from: collection.address,
        to: wallet.address,
        bounced: true,
    });
    expect(wallet.dataHash()).toEqual(dataBefore);
}

get fun `test wallet nft: should reject a content edit from a non-collection sender`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val wallet = nftFixture(collection, owner.address);
    val before = wallet.getNftData();

    val fromAdmin = wallet.sendEditWalletContent(
        admin.address,
        0,
        beginCell().storeString("from admin").endCell(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    val fromOwner = wallet.sendEditWalletContent(
        owner.address,
        0,
        beginCell().storeString("from owner").endCell(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(fromAdmin).toHaveFailedTx<EditWalletContent>({
        from: admin.address,
        to: wallet.address,
        exitCode: Errors.NotFromCollection,
    });
    expect(fromOwner).toHaveFailedTx<EditWalletContent>({
        from: owner.address,
        to: wallet.address,
        exitCode: Errors.NotFromCollection,
    });
    expect(wallet.getNftData()).toEqual(before);
}

get fun `test wallet nft: uninitialized wallet should reject static data request`() {
    val (collection, _, _) = setupTest();
    val walletIndex = collection.getCollectionData().nextWalletIndex;
    val wallet = deployUninitializedWallet(collection.address, walletIndex as uint64);
    val requester = testing.treasury("requester");

    val result = wallet.sendRequestStaticData(
        requester.address,
        0,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveFailedTx<RequestStaticData>({
        from: requester.address,
        to: wallet.address,
        exitCode: Errors.NotInitialized,
    });
    expect(result).toNotHaveTx<ResponseStaticData>({ from: wallet.address });
}

get fun `test wallet nft: should accept empty top-up`() {
    val (collection, _, _) = setupTest();
    val wallet = nftFixture(collection, testing.treasury("owner").address);
    val sender = testing.treasury("sender");
    val before = wallet.getNftData();

    val result = wallet.sendAny(
        sender.address,
        createEmptyCell(),
        { value: DEFAULT_MESSAGE_VALUE },
    );

    expect(result).toHaveSuccessfulTx({ from: sender.address, to: wallet.address });
    expect(result).toNotHaveTx({ from: wallet.address });
    expect(wallet.getNftData()).toEqual(before);
    expect(wallet.seqno()).toEqual(0);
}

/// The Either ref bit requires exactly one ref and no more bits. A ref bit without a ref is
/// malformed.
get fun `test wallet nft: transfer should fail with an Either ref bit but no ref`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("owner");
    val wallet = nftFixture(collection, owner.address);

    val body = beginCell()
        .storeUint(0x5fcc3d14, 32) // op::transfer
        .storeUint(0, 64) // queryId
        .storeAddress(randomAddress("newOwnerAddress")) // new_owner
        .storeAddressNone() // response_destination
        .storeMaybeRef(null) // custom_payload
        .storeCoins(0) // forward_amount
        .storeBool(true) // forward_payload: selector says "ref follows", but no ref
        .endCell();
    val result = wallet.sendAny(
        owner.address,
        body,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveFailedTx<ChangeWalletOwner>({
        from: owner.address,
        to: wallet.address,
        exitCode: Errors.IncorrectForwardPayload,
    });
    expect(wallet.getNftData().ownerAddress!).toEqual(owner.address);
}

get fun `test wallet nft: uninitialized wallet should reject content edit`() {
    val (collection, _, _) = setupTest();
    val walletIndex = collection.getCollectionData().nextWalletIndex;
    val wallet = deployUninitializedWallet(collection.address, walletIndex as uint64);
    val sender = testing.treasury("sender");

    val result = wallet.sendEditWalletContent(
        sender.address,
        0,
        beginCell().storeString("content").endCell(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveFailedTx<EditWalletContent>({
        from: sender.address,
        to: wallet.address,
        exitCode: Errors.NotInitialized,
    });
    expect(wallet.getNftData().isInitialized).toBeFalse();
}

/// TEP-62 lets the wallet ignore `custom_payload`. The transfer and its notification are the same
/// as without it.
get fun `test wallet nft: transfer should ignore a custom payload`() {
    val (collection, _, _) = setupTest();
    val owner = testing.treasury("owner");
    val wallet = nftFixture(collection, owner.address);
    val newOwnerAddress = randomAddress("newOwnerAddress");
    val queryId = 42;
    val forwardAmount = grams("0.01");
    val forwardPayload = beginCell().storeUint(0xDEADBEEF, 32).toSlice();

    val result = wallet.sendChangeWalletOwnerPayloadInline(
        owner.address,
        queryId,
        newOwnerAddress,
        null,
        beginCell().storeUint(0xC0FFEE, 32).endCell(),
        forwardAmount,
        forwardPayload,
        { value: DEFAULT_MESSAGE_VALUE + forwardAmount, bounce: true },
    );

    expect(
        result,
    ).toHaveSuccessfulTx<ChangeWalletOwner>({ from: owner.address, to: wallet.address });
    expect(result).toHaveTx<NotificationForNewOwner>({
        from: wallet.address,
        to: newOwnerAddress,
        value: forwardAmount,
        bounce: false,
        body: NotificationForNewOwner {
            queryId,
            oldOwnerAddress: owner.address,
            forwardPayload: PayloadInline { value: forwardPayload }.toCell().beginParse(),
        }.toCell(),
    });
    expect(wallet.getNftData().ownerAddress!).toEqual(newOwnerAddress);
}

/// A deploy message sent directly to the wallet address runs its body on the uninitialized
/// wallet. No body can initialize it, and the admin can deploy that index after it.
get fun `test wallet nft: predeploy carrying a wallet opcode should not initialize the wallet`() {
    val (collection, admin, _) = setupTest();
    val attacker = testing.treasury("attacker");
    val bounceModes: array<bool> = [true, false];

    var b = 0;
    while (b < bounceModes.size()) {
        var i = 0;
        while (i < ATTACKER_BODY_COUNT) {
            val wallet = nextUnmintedWallet(collection);
            val result = net.send(
                attacker.address,
                createMessage({
                    bounce: bounceModes.get(b),
                    value: DEFAULT_MESSAGE_VALUE,
                    dest: { stateInit: wallet.stateInit! },
                    body: attackerBodies(wallet.address, attacker.address).get(i),
                }),
            );
            // the deploy succeeds, so the wallet code runs each body
            expect(testing.isDeployed(wallet.address)).toBeTrue();
            if (i == 0) {
                expect(result).toHaveFailedTx<DeployWallet>({
                    from: attacker.address,
                    to: wallet.address,
                    exitCode: Errors.NotFromCollection,
                });
            }

            expectNotInitialized(wallet.address);
            expectAdminMints(collection, admin);
            i += 1;
        }
        b += 1;
    }
}

/// Wallet code with storage that the attacker selects deploys to a different address. The wallet
/// of the collection does not change, and the admin deploys it.
get fun `test wallet nft: wallet deployed with attacker-chosen data should not be the collection's wallet`() {
    val (collection, admin, _) = setupTest();
    val attacker = testing.treasury("attacker");
    val walletIndex = collection.getCollectionData().nextWalletIndex;
    val realAddress = collection.getNftAddressByIndex(walletIndex);

    val fakeState = attackerState(collection.address, walletIndex as uint64, attacker.address);
    val fakeAddress = AutoDeployAddress { stateInit: fakeState }.calculateAddress();
    expect(
        net.send(
            attacker.address,
            createMessage({ bounce: false, value: DEFAULT_MESSAGE_VALUE, dest: {
                    stateInit: fakeState,
                } }),
        ),
    ).toHaveSuccessfulDeploy({ to: fakeAddress });

    expect(fakeAddress == realAddress).toBeFalse();
    expect(testing.isDeployed(realAddress)).toBeFalse();
    // the fake wallet shows the collection and index, so holders must check
    // get_nft_address_by_index
    val fakeData = AgenticWallet.fromAddress(fakeAddress).getNftData();
    expect(fakeData.collectionAddress).toEqual(collection.address);
    expect(fakeData.walletIndex).toEqual(walletIndex);

    expectAdminMints(collection, admin);
    expect(AgenticWallet.fromAddress(fakeAddress).getNftData()).toEqual(fakeData);
}

/// A StateInit with a hash that is not the wallet address can not initialize the wallet. This is
/// true for an unused address, a predeployed address and an address that the collection deployed.
get fun `test wallet nft: attacker StateInit sent to the real wallet address should be ignored`() {
    val (collection, admin, _) = setupTest();
    val attacker = testing.treasury("attacker");
    val bounceModes: array<bool> = [true, false];

    var b = 0;
    while (b < bounceModes.size()) {
        var predeploy = 0;
        while (predeploy < 2) {
            val wallet = nextUnmintedWallet(collection);
            val walletIndex = collection.getCollectionData().nextWalletIndex;
            if (predeploy == 1) {
                deployUninitializedWallet(collection.address, walletIndex);
            }

            val result = sendWithStateInit(
                attacker.address,
                wallet.address,
                attackerState(collection.address, walletIndex, attacker.address),
                bounceModes.get(b),
            );
            if (predeploy == 0) {
                expect(result).toHaveTx({
                    from: attacker.address,
                    to: wallet.address,
                    computePhaseSkipped: true,
                });
            } else {
                expect(result).toHaveSuccessfulTx({ from: attacker.address, to: wallet.address });
            }

            expectNotInitialized(wallet.address);
            expectAdminMints(collection, admin);
            predeploy += 1;
        }

        // an already deployed wallet keeps its state
        val walletIndex = collection.getCollectionData().nextWalletIndex - 1;
        val minted = AgenticWallet.fromAddress(collection.getNftAddressByIndex(walletIndex));
        val dataBefore = minted.getNftData();
        sendWithStateInit(
            attacker.address,
            minted.address,
            attackerState(collection.address, walletIndex as uint64, attacker.address),
            bounceModes.get(b),
        );
        expect(minted.getNftData()).toEqual(dataBefore);
        expect(minted.seqno()).toEqual(0);
        expect(minted.getPublicKey()).toEqual(DELEGATE_PUBLIC_KEY);
        b += 1;
    }
}

/// A wallet address that is not deployed never accepts an external with a StateInit. This is
/// true with or without funds, and with the real or an attacker StateInit. The admin can still
/// deploy that index.
get fun `test wallet nft: external with a StateInit should not deploy or initialize the wallet`() {
    val (collection, admin, _) = setupTest();
    val attacker = testing.treasury("attacker");
    val attackerKey = namedKeyPair("attacker-key");

    var funded = 0;
    while (funded < 2) {
        val wallet = nextUnmintedWallet(collection);
        val walletIndex = collection.getCollectionData().nextWalletIndex;
        if (funded == 1) {
            // a plain transfer leaves the account uninit, with a balance to pay for gas
            net.send(
                attacker.address,
                createMessage({ bounce: false, value: grams("0.002"), dest: wallet.address }),
            );
        }
        val request = createExternalSignedRequest(
            attackerKey,
            wallet.address,
            0,
            [sendMessageAction(attacker.address, grams("0.01"))],
        );

        val withRealState = net.sendExternal(
            net.createExternalMessage(wallet.address, request, toStateInit(wallet.stateInit!)),
        );
        expect(withRealState).toBeNotAccepted();
        if (funded == 1) {
            // the wallet code ran on the deployment storage and rejected the request
            expect(withRealState).toHaveExternalVmExitCode(Errors.NotInitialized);
        }
        expect(testing.isDeployed(wallet.address)).toBeFalse();

        val withAttackerState = net.sendExternal(
            net.createExternalMessage(
                wallet.address,
                request,
                toStateInit(attackerState(collection.address, walletIndex, attacker.address)),
            ),
        );
        expect(withAttackerState).toBeNotAccepted();
        expect(testing.isDeployed(wallet.address)).toBeFalse();

        expectAdminMints(collection, admin);
        funded += 1;
    }
}

/// A frozen wallet unfreezes only with its own last state. An attacker StateInit leaves it
/// frozen. The correct StateInit restores the same data, including the seqno.
get fun `test wallet nft: frozen wallet should only unfreeze to its own state`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("frozen-owner");
    val attacker = testing.treasury("attacker");
    val delegateKey = namedKeyPair("frozen-delegate");
    val (_, wallet) = mintWallet(
        collection,
        admin,
        AgenticWalletInitParams.create(
            owner.address,
            createEmptyCell(),
            delegateKey.publicKey as uint256,
            0,
            emptyForwardPayload(),
        ),
    );
    wallet.sendOwnerActions(
        owner.address,
        0,
        [sendMessageAction(randomAddress("drain"), 0, null, SEND_MODE_CARRY_ALL_BALANCE)],
        { value: DEFAULT_MESSAGE_VALUE },
    );
    expect(testing.getAccountBalance(wallet.address)).toEqual(0);
    val account = testing.getAccountState(wallet.address)!;
    if (account.storage.state !is TlbAccountStateActive) {
        Assert.fail("Expected an active wallet");
    }
    val ownState: ContractState = {
        code: account.storage.state.stateInit.code!,
        data: account.storage.state.stateInit.data!,
    };
    val seqnoBefore = wallet.seqno();

    // makes a storage debt just above the freeze limit. For a wallet this small, 32-bit unix
    // time can not reach the delete limit.
    val limits = testing.getConfig().getGasPrices(BASECHAIN).other;
    val targetDebt = limits.freezeDueLimit + limits.freezeDueLimit / 10;
    expect(targetDebt).toBeLess(limits.deleteDueLimit);
    val feePerDay = testing.getAccountStorageFee(wallet.address, 86400)!;
    val frozenAt = blockchain.now() + (targetDebt / feePerDay + 1) * 86400;
    expect(frozenAt).toBeLess(1 << 32);
    testing.setNow(frozenAt);
    net.send(
        attacker.address,
        createMessage({ bounce: false, value: grams("0.001"), dest: wallet.address }),
    );
    expectFrozen(wallet.address);

    sendWithStateInit(
        attacker.address,
        wallet.address,
        attackerState(collection.address, 0, attacker.address),
        false,
        grams("2"),
    );
    expectFrozen(wallet.address);

    sendWithStateInit(owner.address, wallet.address, ownState, false, grams("2"));
    expect(wallet.dataHash()).toEqual(ownState.data.hash());
    expect(wallet.seqno()).toEqual(seqnoBefore);

    val receiver = randomAddress("after-unfreeze");
    val request = createExternalSignedRequest(
        delegateKey,
        wallet.address,
        seqnoBefore,
        [sendMessageAction(receiver, grams("0.001"))],
    );
    expect(wallet.sendExternalSigned(request)!).toHaveTx({ from: wallet.address, to: receiver });
    expect(wallet.seqno()).toEqual(seqnoBefore + 1);
}

const ATTACKER_BODY_COUNT = 9

/// All wallet message bodies that an attacker can attach to a deploy message, `DeployWallet` first.
fun attackerBodies(wallet: address, attacker: address): array<cell> {
    val attackerKey = namedKeyPair("attacker-key");
    return [
        DeployWallet {
            queryId: 0,
            initParams: AgenticWalletInitParams
                .create(
                    attacker,
                    createEmptyCell(),
                    attackerKey.publicKey as uint256,
                    0,
                    emptyForwardPayload(),
                )
                .toCell(),
        }.toCell(),
        changeOwnerBody(attacker),
        ChangeWalletDelegate {
            queryId: 0,
            newDelegatePublicKey: attackerKey.publicKey,
        }.toCell(),
        EditWalletContent {
            queryId: 0,
            newContent: createEmptyCell(),
        }.toCell(),
        RequestStaticData { queryId: 0 }.toCell(),
        OwnerActionRequest {
            queryId: 0,
            outActions: buildOutActions([sendMessageAction(attacker, grams("0.01"))]),
        }.toCell(),
        createInternalSignedRequest(
            attackerKey,
            wallet,
            0,
            [sendMessageAction(attacker, grams("0.01"))],
        ).toCell(),
        createEmptyCell(),
        "attacker".toCell(),
    ];
}

/// Wallet code with initialized storage that the attacker selects for wallet `walletIndex`.
fun attackerState(collection: address, walletIndex: uint64, attacker: address): ContractState {
    return {
        code: build("AgenticWallet"),
        data: AgenticWalletStorage {
            walletIndex,
            collectionAddress: collection,
            seqno: 0,
            ownerAddress: attacker,
            content: createEmptyCell(),
            delegatePublicKey: namedKeyPair("attacker-key").publicKey as uint256,
        }.toCell(),
    };
}

fun toStateInit(state: ContractState): StateInit {
    return {
        fixedPrefixLength: null,
        special: null,
        code: state.code,
        data: state.data,
        library: null,
    };
}

/// Sends an internal message to `dest` with `state` as its StateInit. The StateInit does not need
/// to match `dest`.
fun sendWithStateInit(
    from: address,
    dest: address,
    state: ContractState,
    bounce: bool,
    value: coins = DEFAULT_MESSAGE_VALUE,
): SendResultList {
    val init: TlbMaybe<TlbEither<StateInit, Cell<StateInit>>> = TlbMaybe.just(
        TlbEither.right(toStateInit(state).toCell()),
    );
    val message = TlbMessageRelaxed<RemainingBitsAndRefs> {
        info: TlbIntMsgInfoRelaxed {
            ihrDisabled: true,
            bounce,
            bounced: false,
            src: createAddressNone(),
            dest,
            value: { grams: value, other: [] },
            extraFlags: 0,
            fwdFee: 0,
            createdLt: 0,
            createdAt: 0,
        },
        init,
        body: TlbEither<RemainingBitsAndRefs, Cell<RemainingBitsAndRefs>>.left(createEmptySlice()),
    };
    return net.send(from, OutMessage { messageCell: message.toCell() });
}

/// The next wallet of the collection, before its deploy.
fun nextUnmintedWallet(collection: AgenticCollection): AgenticWallet {
    val walletIndex = collection.getCollectionData().nextWalletIndex;
    val wallet = AgenticWallet.fromStorage({
        walletIndex: walletIndex as uint64,
        collectionAddress: collection.address,
        seqno: 0,
    });
    expect(wallet.address).toEqual(collection.getNftAddressByIndex(walletIndex));
    return wallet;
}

/// Expects that the admin deploys the next wallet of the collection with its own init params.
fun expectAdminMints(collection: AgenticCollection, admin: Treasury) {
    val walletIndex = collection.getCollectionData().nextWalletIndex;
    val owner = randomAddress("admin-chosen-owner");
    val content = beginCell().storeString("admin-content").endCell();
    val (result, wallet) = mintWallet(
        collection,
        admin,
        AgenticWalletInitParams.create(
            owner,
            content,
            DELEGATE_PUBLIC_KEY,
            0,
            emptyForwardPayload(),
        ),
    );

    expect(result).toHaveSuccessfulTx<DeployWallet>({
        from: collection.address,
        to: wallet.address,
    });
    val data = wallet.getNftData();
    expect(data.isInitialized).toBeTrue();
    expect(data.walletIndex).toEqual(walletIndex);
    expect(data.ownerAddress!).toEqual(owner);
    expect(data.content!.hash()).toEqual(content.hash());
    expect(wallet.getPublicKey()).toEqual(DELEGATE_PUBLIC_KEY);
    expect(collection.getCollectionData().nextWalletIndex).toEqual(walletIndex + 1);
}
