import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/errors"
import "@contracts/fees"
import "@contracts/messages"
import "@tests/fixtures"
import "@tests/utils"
import "@wrappers/AgenticCollection.gen"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/send"
import "@wrappers/utils"

const MIN_EDGE_DELTA = 1

/// The owner sends the whole balance away (mode 128). Then the owner tops up the wallet with less
/// than the storage reserve, so the rest amount, not the incoming value, limits the transfer value.
fun drainItemBelowStorageMinimum(item: AgenticWallet, owner: Treasury) {
    item.sendOwnerActions(
        owner.address,
        0,
        [sendMessageAction(owner.address, 0, null, SEND_MODE_CARRY_ALL_BALANCE)],
        { value: grams("0.1") },
    );
    item.sendAny(owner.address, createEmptyCell(), { value: MIN_WALLET_STORAGE / 2 });
    expect(testing.getAccountBalance(item.address)).toBeLess(MIN_WALLET_STORAGE);
}

/// The layout of `ChangeWalletOwner`, with the forward payload typed as `PayloadInline |
/// PayloadInRef`: the generated `sendChangeWalletOwner` takes this type, the contract struct
/// has raw bits.
struct OwnershipTransferBody {
    queryId: uint64
    newOwnerAddress: address
    sendExcessesTo: address?
    customPayload: cell?
    forwardAmount: coins
    forwardPayload: PayloadInline | PayloadInRef
}

fun OwnershipTransferBody.toCell(self): cell {
    return beginCell()
        .storeUint(0x5fcc3d14, 32)
        .storeAny(self.queryId)
        .storeAny(self.newOwnerAddress)
        .storeAny(self.sendExcessesTo)
        .storeAny(self.customPayload)
        .storeAny(self.forwardAmount)
        .storeAny(self.forwardPayload)
        .endCell();
}

fun makeOwnershipTransferBody(
    newOwnerAddress: address,
    sendExcessesTo: address?,
    forwardAmount: coins,
    forwardPayload: slice,
): OwnershipTransferBody {
    val (bodyBits, bodyRefs) = OwnershipTransferBody {
        queryId: 0,
        newOwnerAddress,
        sendExcessesTo,
        customPayload: null,
        forwardAmount,
        forwardPayload: emptyForwardPayload(),
    }
    .toCell()
    .beginParse()
    .remainingBitsAndRefsCount();

    val payload: PayloadInline | PayloadInRef = (1023 - bodyBits) >
        forwardPayload.remainingBitsCount() &&
        (4 - bodyRefs) > forwardPayload.remainingRefsCount()
        ? PayloadInline { value: forwardPayload }
        : PayloadInRef { value: forwardPayload.toCell() };

    return {
        queryId: 0,
        newOwnerAddress,
        sendExcessesTo,
        customPayload: null,
        forwardAmount,
        forwardPayload: payload,
    };
}

fun calculateMinimalTransferValue(
    itemAddress: address,
    body: OwnershipTransferBody,
    balanceBefore: coins,
): coins {
    var value = 0;
    var previous = -1;
    val bodyCell = body.toCell();

    while (value != previous) {
        previous = value;

        val fwdFee = estimateMessageForwardFee(bodyCell, itemAddress, true, value);
        var required = MIN_WALLET_STORAGE - balanceBefore;
        if (required < 0) {
            required = 0;
        }
        if (body.forwardAmount != 0) {
            required += body.forwardAmount + fwdFee;
        }
        if (body.sendExcessesTo != null) {
            required += fwdFee;
        }

        value = required;
    }

    return value;
}

fun calculateRestAmount(
    balanceBefore: coins,
    msgValue: coins,
    body: OwnershipTransferBody,
    fwdFee: coins,
): coins {
    var restAmount = balanceBefore + msgValue - MIN_WALLET_STORAGE;
    if (body.forwardAmount != 0) {
        restAmount -= (body.forwardAmount + fwdFee);
    }
    if (body.sendExcessesTo != null) {
        restAmount -= fwdFee;
    }
    return restAmount;
}

/// AgenticCollection has no batch deploy. A single deploy that skips an index must fail the same
/// way.
get fun `test mutation: deploy should reject a skipped index and preserve collection state`() {
    val (nftCollection, deployer, _) = setupTest();
    val nextItemIndex = nftCollection.getCollectionData().nextWalletIndex;
    val skippedAddress = nftCollection.getNftAddressByIndex(nextItemIndex);
    val gapAddress = nftCollection.getNftAddressByIndex(nextItemIndex + 2);
    val result = nftCollection.sendRelayDeployWallet(
        deployer.address,
        0,
        nextItemIndex + 2,
        TEST_WALLET_ATTACH_AMOUNT,
        walletInitParams(randomAddress("gapOwner"), beginCell().storeString("gap").endCell()),
        { value: grams("0.5"), bounce: true },
    );

    expect(result).toHaveFailedTx<RelayDeployWallet>({
        from: deployer.address,
        to: nftCollection.address,
        exitCode: Errors.InvalidWalletIndex,
    });
    expect(result).toNotHaveTx({ from: nftCollection.address, deploy: true });
    expect(nftCollection.getCollectionData().nextWalletIndex).toEqual(nextItemIndex);
    expect(testing.isDeployed(skippedAddress)).toBeFalse();
    expect(testing.isDeployed(gapAddress)).toBeFalse();
}

/// AgenticCollection has no batch deploy, so the test sends the redeploy and the new deploy one by
/// one.
get fun `test mutation: redeploy should not over-increment the next wallet index`() {
    val (nftCollection, deployer, _) = setupTest();
    val owner = testing.treasury("mutation-redeploy-owner");

    nftFixture(nftCollection, owner.address);
    nftFixture(nftCollection, owner.address);

    val nextItemIndex = nftCollection.getCollectionData().nextWalletIndex;
    expect(nextItemIndex).toEqual(2);

    val redeploy = nftCollection.sendRelayDeployWallet(
        deployer.address,
        0,
        0,
        TEST_WALLET_ATTACH_AMOUNT,
        walletInitParams(owner.address, beginCell().storeString("redeploy").endCell()),
        { value: grams("0.1"), bounce: true },
    );

    expect(redeploy).toHaveSuccessfulTx<RelayDeployWallet>({
        from: deployer.address,
        to: nftCollection.address,
    });
    expect(nftCollection.getCollectionData().nextWalletIndex).toEqual(nextItemIndex);

    val result = nftCollection.sendRelayDeployWallet(
        deployer.address,
        0,
        null,
        TEST_WALLET_ATTACH_AMOUNT,
        walletInitParams(owner.address, beginCell().storeString("redeploy").endCell()),
        { value: grams("0.1"), bounce: true },
    );

    expect(result).toHaveSuccessfulTx<RelayDeployWallet>({
        from: deployer.address,
        to: nftCollection.address,
    });
    expect(nftCollection.getCollectionData().nextWalletIndex).toEqual(nextItemIndex + 1);

    val freshNftAddress = nftCollection.getNftAddressByIndex(nextItemIndex);
    expect(result).toHaveSuccessfulDeploy({ from: nftCollection.address, to: freshNftAddress });
}

get fun `test mutation: uninitialized wallet getter should expose only the deployment storage`() {
    val (nftCollection, _, _) = setupTest();
    val walletIndex = nftCollection.getCollectionData().nextWalletIndex;
    val nftItem = deployUninitializedWallet(nftCollection.address, walletIndex as uint64);
    expect(nftItem.address).toEqual(nftCollection.getNftAddressByIndex(walletIndex));

    val data = nftItem.getNftData();
    expect(data.isInitialized).toBeFalse();
    expect(data.walletIndex).toEqual(walletIndex);
    expect(data.collectionAddress).toEqual(nftCollection.address);
    expect(data.ownerAddress == null).toBeTrue();
    expect(data.content == null).toBeTrue();
}

get fun `test mutation: uninitialized wallet should reject initialization from a non-collection sender`() {
    val (nftCollection, _, _) = setupTest();
    val outsider = testing.treasury("mutation-uninitialized-outsider");
    val walletIndex = nftCollection.getCollectionData().nextWalletIndex;
    val nftItem = deployUninitializedWallet(nftCollection.address, walletIndex as uint64);

    val result = nftItem.sendDeployWallet(
        outsider.address,
        0,
        walletInitParams(outsider.address, beginCell().storeString("forbidden").endCell()),
        { value: grams("0.05"), bounce: true },
    );

    expect(result).toHaveFailedTx({
        from: outsider.address,
        to: nftItem.address,
        exitCode: Errors.NotFromCollection,
    });

    val data = nftItem.getNftData();
    expect(data.isInitialized).toBeFalse();
    expect(data.collectionAddress).toEqual(nftCollection.address);
    expect(data.ownerAddress == null).toBeTrue();
    expect(data.content == null).toBeTrue();
}

get fun `test mutation: ownership transfer should fail one nanogram below forward-only threshold`() {
    val (nftCollection, _, _) = setupTest();
    val owner = testing.treasury("mutation-threshold-owner");
    val nftItem = nftFixture(nftCollection, owner.address);
    drainItemBelowStorageMinimum(nftItem, owner);
    val nextOwner = randomAddress("nextOwner");
    val transferBody = makeOwnershipTransferBody(
        nextOwner,
        null,
        grams("0.01"),
        createEmptySlice(),
    );

    val balanceBefore = testing.getAccountBalance(nftItem.address);
    val minimalValue = calculateMinimalTransferValue(nftItem.address, transferBody, balanceBefore);
    val result = nftItem.sendChangeWalletOwner(
        owner.address,
        transferBody.queryId,
        transferBody.newOwnerAddress,
        transferBody.sendExcessesTo,
        transferBody.customPayload,
        transferBody.forwardAmount,
        transferBody.forwardPayload,
        { value: minimalValue - MIN_EDGE_DELTA, bounce: true },
    );

    expect(result).toHaveFailedTx<ChangeWalletOwner>({
        from: owner.address,
        to: nftItem.address,
        exitCode: Errors.TooSmallRestAmount,
    });
    expect(nftItem.getNftData().ownerAddress!).toEqual(owner.address);
}

get fun `test mutation: ownership transfer with zero forward amount should exhaust rest exactly`() {
    val (nftCollection, _, _) = setupTest();
    val owner = testing.treasury("mutation-zero-forward-owner");
    val nftItem = nftFixture(nftCollection, owner.address);
    drainItemBelowStorageMinimum(nftItem, owner);
    val nextOwner = randomAddress("nextOwner");
    val excessesAddress = randomAddress("excessesAddress");
    val transferBody = makeOwnershipTransferBody(nextOwner, excessesAddress, 0, createEmptySlice());

    val balanceBefore = testing.getAccountBalance(nftItem.address);
    val exactValue = calculateMinimalTransferValue(nftItem.address, transferBody, balanceBefore);
    val fwdFee = estimateMessageForwardFee(
        transferBody.toCell(),
        nftItem.address,
        true,
        exactValue,
    );
    val expectedRestAmount = calculateRestAmount(balanceBefore, exactValue, transferBody, fwdFee);
    val result = nftItem.sendChangeWalletOwner(
        owner.address,
        transferBody.queryId,
        transferBody.newOwnerAddress,
        transferBody.sendExcessesTo,
        transferBody.customPayload,
        transferBody.forwardAmount,
        transferBody.forwardPayload,
        { value: exactValue, bounce: true },
    );

    expect(expectedRestAmount).toEqual(0);
    expect(result).toHaveSuccessfulTx<ChangeWalletOwner>({
        from: owner.address,
        to: nftItem.address,
    });
    expect(result).toNotHaveTx<NotificationForNewOwner>({ from: nftItem.address, to: nextOwner });
    expect(result).toHaveTx<ReturnExcessesBack>({
        from: nftItem.address,
        to: excessesAddress,
        bounce: false,
        value: expectedRestAmount,
    });
    expect(nftItem.getNftData().ownerAddress!).toEqual(nextOwner);
}

get fun `test mutation: ownership transfer with forward amount should emit exact zero-rest payouts`() {
    val (nftCollection, _, _) = setupTest();
    val owner = testing.treasury("mutation-forward-owner");
    val nftItem = nftFixture(nftCollection, owner.address);
    drainItemBelowStorageMinimum(nftItem, owner);
    val nextOwner = randomAddress("nextOwner");
    val excessesAddress = randomAddress("excessesAddress");
    val forwardAmount = grams("0.01");
    val transferBody = makeOwnershipTransferBody(
        nextOwner,
        excessesAddress,
        forwardAmount,
        createEmptySlice(),
    );

    val balanceBefore = testing.getAccountBalance(nftItem.address);
    val exactValue = calculateMinimalTransferValue(nftItem.address, transferBody, balanceBefore);
    val fwdFee = estimateMessageForwardFee(
        transferBody.toCell(),
        nftItem.address,
        true,
        exactValue,
    );
    val expectedRestAmount = calculateRestAmount(balanceBefore, exactValue, transferBody, fwdFee);
    val result = nftItem.sendChangeWalletOwner(
        owner.address,
        transferBody.queryId,
        transferBody.newOwnerAddress,
        transferBody.sendExcessesTo,
        transferBody.customPayload,
        transferBody.forwardAmount,
        transferBody.forwardPayload,
        { value: exactValue, bounce: true },
    );

    expect(expectedRestAmount).toEqual(0);
    expect(result).toHaveSuccessfulTx<ChangeWalletOwner>({
        from: owner.address,
        to: nftItem.address,
    });
    expect(result).toHaveTx<NotificationForNewOwner>({
        from: nftItem.address,
        to: nextOwner,
        bounce: false,
        value: forwardAmount,
    });
    expect(result).toHaveTx<ReturnExcessesBack>({
        from: nftItem.address,
        to: excessesAddress,
        bounce: false,
        value: expectedRestAmount,
    });
    expect(nftItem.getNftData().ownerAddress!).toEqual(nextOwner);
}
