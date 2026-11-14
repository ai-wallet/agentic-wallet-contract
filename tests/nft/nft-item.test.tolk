import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/errors"
import "@contracts/messages"
import "@tests/fixtures"
import "@wrappers/AgenticCollection.gen"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/send"

get fun `test nft: should transfer ownership`() {
    val (nftCollection, _, _) = setupTest();
    val nftOwner = testing.treasury("nft-owner");
    val nftReceiverAddress = randomAddress("nftReceiverAddress");

    val nftItem = nftFixture(nftCollection, nftOwner.address);

    val ownerBeforeTransfer = nftItem.getNftData().ownerAddress;
    expect(ownerBeforeTransfer!).toEqual(nftOwner.address);

    val result = nftItem.sendChangeWalletOwnerPayloadInline(
        nftOwner.address,
        0,
        nftReceiverAddress,
        null,
        null,
        0,
        createEmptySlice(),
        { value: grams("0.05"), bounce: true },
    );

    expect(result).toHaveSuccessfulTx<ChangeWalletOwner>({
        from: nftOwner.address,
        to: nftItem.address,
    });

    // no notification: forwardAmount is 0
    expect(result).toNotHaveTx<NotificationForNewOwner>({
        from: nftItem.address,
        to: nftReceiverAddress,
    });

    val ownerAfterTransfer = nftItem.getNftData().ownerAddress;
    expect(ownerAfterTransfer!).toEqual(nftReceiverAddress);
}

get fun `test nft: should transfer ownership and return excesses`() {
    val (nftCollection, _, _) = setupTest();

    val nftOwner = testing.treasury("nft-owner");
    val nftReceiverAddress = randomAddress("nftReceiverAddress");
    val excessesAddress = randomAddress("excessesAddress");

    val nftItem = nftFixture(nftCollection, nftOwner.address);

    val ownerBeforeTransfer = nftItem.getNftData().ownerAddress;
    expect(ownerBeforeTransfer!).toEqual(nftOwner.address);

    val result = nftItem.sendChangeWalletOwnerPayloadInline(
        nftOwner.address,
        0,
        nftReceiverAddress,
        excessesAddress,
        null,
        0,
        createEmptySlice(),
        { value: grams("0.05"), bounce: true },
    );

    expect(result).toHaveSuccessfulTx<ChangeWalletOwner>({
        from: nftOwner.address,
        to: nftItem.address,
    });

    expect(result).toHaveTx<ReturnExcessesBack>({
        from: nftItem.address,
        to: excessesAddress,
        bounce: false,
    });

    val ownerAfterTransfer = nftItem.getNftData().ownerAddress;
    expect(ownerAfterTransfer!).toEqual(nftReceiverAddress);
}

get fun `test nft: should reject a transfer from a non-owner`() {
    val (nftCollection, _, _) = setupTest();
    val nftOwner = testing.treasury("nft-owner");
    val notOwner = testing.treasury("not-owner");
    val nftReceiverAddress = randomAddress("nftReceiverAddress");

    val nftItem = nftFixture(nftCollection, nftOwner.address);

    val ownerBeforeTransfer = nftItem.getNftData().ownerAddress;
    expect(ownerBeforeTransfer!).toEqual(nftOwner.address);

    val result = nftItem.sendChangeWalletOwnerPayloadInline(
        notOwner.address,
        0,
        nftReceiverAddress,
        null,
        null,
        0,
        createEmptySlice(),
        { value: grams("0.05"), bounce: true },
    );

    expect(result).toHaveFailedTx<ChangeWalletOwner>({
        from: notOwner.address,
        to: nftItem.address,
        exitCode: Errors.NotFromOwner,
    });

    val ownerAfterTransfer = nftItem.getNftData().ownerAddress;
    expect(ownerAfterTransfer!).toEqual(ownerBeforeTransfer!);
}

get fun `test nft: should transfer ownership with notification`() {
    val (nftCollection, _, _) = setupTest();
    val nftOwner = testing.treasury("nft-owner");
    val nftReceiverAddress = randomAddress("nftReceiverAddress");

    val nftItem = nftFixture(nftCollection, nftOwner.address);

    val ownerBeforeTransfer = nftItem.getNftData().ownerAddress;
    expect(ownerBeforeTransfer!).toEqual(nftOwner.address);

    val forwardAmount = grams("0.01");
    val forwardBody = beginCell().storeUint(0, 32).storeString("Hello!").endCell();
    val queryId = 42;

    val result = nftItem.sendChangeWalletOwnerPayloadInRef(
        nftOwner.address,
        queryId,
        nftReceiverAddress,
        null,
        null,
        forwardAmount,
        forwardBody,
        { value: grams("0.05"), bounce: true },
    );

    expect(result).toHaveSuccessfulTx<ChangeWalletOwner>({
        from: nftOwner.address,
        to: nftItem.address,
    });

    expect(result).toHaveTx<NotificationForNewOwner>({
        from: nftItem.address,
        to: nftReceiverAddress,
        value: forwardAmount,
        bounce: false,
        body: NotificationForNewOwner {
            queryId,
            oldOwnerAddress: nftOwner.address,
            forwardPayload: beginCell()
                .storeBool(true)
                .storeRef(forwardBody)
                .toSlice() as RemainingBitsAndRefs,
        }.toCell(),
    });

    val ownerAfterTransfer = nftItem.getNftData().ownerAddress;
    expect(ownerAfterTransfer!).toEqual(nftReceiverAddress);
}

get fun `test nft: should get static data`() {
    val (nftCollection, _, _) = setupTest();
    val nftOwner = testing.treasury("nft-owner");
    val randomTreasury = testing.treasury("random-treasury");

    val nftItem = nftFixture(nftCollection, nftOwner.address);

    val queryId = 42;
    val nftData = nftItem.getNftData();

    val result = nftItem.sendRequestStaticData(
        randomTreasury.address,
        queryId,
        { value: grams("0.05"), bounce: true },
    );

    expect(result).toHaveSuccessfulTx<RequestStaticData>({
        from: randomTreasury.address,
        to: nftItem.address,
    });

    expect(result).toHaveTx<ResponseStaticData>({
        from: nftItem.address,
        to: randomTreasury.address,
        bounce: false,
        body: ResponseStaticData {
            queryId,
            walletIndex: nftData.walletIndex as uint256,
            collectionAddress: nftData.collectionAddress,
        }.toCell(),
    });
}

get fun `test nft: should fail when the new owner is in another workchain`() {
    val (nftCollection, _, _) = setupTest();
    val nftOwner = testing.treasury("nft-owner");
    val nftReceiverAddress = randomAddress("random_user", -1);

    val nftItem = nftFixture(nftCollection, nftOwner.address);

    val result = nftItem.sendChangeWalletOwnerPayloadInline(
        nftOwner.address,
        0,
        nftReceiverAddress,
        null,
        null,
        0,
        createEmptySlice(),
        { value: grams("0.05"), bounce: true },
    );

    expect(result).toHaveFailedTx<ChangeWalletOwner>({
        from: nftOwner.address,
        to: nftItem.address,
        exitCode: Errors.InvalidWorkchain,
    });
}

/// AgenticWallet accepts GRAM with unknown bodies, as other wallets do. It does not throw 0xFFFF,
/// and the message has no effect.
get fun `test nft: unknown opcode should be accepted without effect`() {
    val (nftCollection, _, _) = setupTest();
    val nftOwner = testing.treasury("nft-owner");
    val randomTreasury = testing.treasury("random-treasury");

    val nftItem = nftFixture(nftCollection, nftOwner.address);

    val queryId = 42;
    val invalidOpcode = 0x123459;
    val nftData = nftItem.getNftData();

    val result = nftItem.sendAny(
        randomTreasury.address,
        beginCell().storeUint(invalidOpcode, 32).storeUint(queryId, 64).endCell(),
        { value: grams("0.05"), bounce: true },
    );

    expect(result).toHaveSuccessfulTx({
        from: randomTreasury.address,
        to: nftItem.address,
    });
    expect(result).toNotHaveTx({ from: nftItem.address });
    expect(nftItem.getNftData()).toEqual(nftData);
    expect(nftItem.seqno()).toEqual(0);
}

get fun `test nft: should fail when the response address is in another workchain`() {
    val (nftCollection, _, _) = setupTest();
    val nftOwner = testing.treasury("nft-owner");
    val nftReceiverAddress = randomAddress("nftReceiverAddress");
    val excessesAddress = randomAddress("excesses", MASTERCHAIN);

    val nftItem = nftFixture(nftCollection, nftOwner.address);

    val result = nftItem.sendChangeWalletOwnerPayloadInline(
        nftOwner.address,
        0,
        nftReceiverAddress,
        excessesAddress,
        null,
        0,
        createEmptySlice(),
        { value: grams("0.05"), bounce: true },
    );

    expect(result).toHaveFailedTx<ChangeWalletOwner>({
        from: nftOwner.address,
        to: nftItem.address,
        exitCode: Errors.InvalidWorkchain,
    });
}

get fun `test nft: should fail without a forward payload`() {
    val (nftCollection, _, _) = setupTest();
    val nftOwner = testing.treasury("nft-owner");
    val nftReceiverAddress = randomAddress("nftReceiverAddress");
    val responseAddress = randomAddress("responseAddress");

    val nftItem = nftFixture(nftCollection, nftOwner.address);

    val ownerBeforeTransfer = nftItem.getNftData().ownerAddress;
    expect(ownerBeforeTransfer!).toEqual(nftOwner.address);

    val body = beginCell()
        .storeUint(0x5fcc3d14, 32) // op::transfer
        .storeUint(42, 64) // queryId
        .storeAddress(nftReceiverAddress) // new_owner
        .storeAddress(responseAddress) // response_destination
        .storeMaybeRef(null) // custom_payload
        .storeCoins(999) // forward_amount
        // no forward_payload
        .endCell();

    val result = nftItem.sendAny(nftOwner.address, body, { value: grams("0.05"), bounce: true });

    expect(result).toHaveFailedTx({
        from: nftOwner.address,
        to: nftItem.address,
        body,
        exitCode: Errors.IncorrectForwardPayload,
    });

    val ownerAfterTransfer = nftItem.getNftData().ownerAddress;
    expect(ownerAfterTransfer!).toEqual(ownerBeforeTransfer!);
}

get fun `test nft: should fail with a malformed Either forward payload`() {
    val (nftCollection, _, _) = setupTest();
    val nftOwner = testing.treasury("nft-owner");
    val nftReceiverAddress = randomAddress("nftReceiverAddress");
    val responseAddress = randomAddress("responseAddress");

    val nftItem = nftFixture(nftCollection, nftOwner.address);

    // Either bit 1 (ref) followed by extra bits: malformed in TEP-62
    val malformedPayload = beginCell()
        .storeBool(true) // Either bit: a ref follows
        .storeUint(0xDEAD, 16) // extra inline bits make it invalid
        .storeRef(beginCell().endCell())
        .toSlice();

    val body = beginCell()
        .storeUint(0x5fcc3d14, 32) // op::transfer
        .storeUint(42, 64) // queryId
        .storeAddress(nftReceiverAddress) // new_owner
        .storeAddress(responseAddress) // response_destination
        .storeMaybeRef(null) // custom_payload
        .storeCoins(0) // forward_amount
        .storeSlice(malformedPayload)
        .endCell();

    val result = nftItem.sendAny(nftOwner.address, body, { value: grams("0.05"), bounce: true });

    expect(result).toHaveFailedTx({
        from: nftOwner.address,
        to: nftItem.address,
        body,
        exitCode: Errors.IncorrectForwardPayload,
    });
}

get fun `test nft: should transfer ownership with an inline forward payload`() {
    val (nftCollection, _, _) = setupTest();
    val nftOwner = testing.treasury("nft-owner");
    val nftReceiverAddress = randomAddress("nftReceiverAddress");

    val nftItem = nftFixture(nftCollection, nftOwner.address);
    val queryId = 42;
    val forwardAmount = grams("0.01");

    // forward_payload as an inline slice, not a ref
    val forwardPayloadSlice = beginCell().storeUint(0xDEADBEEF, 32).toSlice();

    val result = nftItem.sendChangeWalletOwnerPayloadInline(
        nftOwner.address,
        queryId,
        nftReceiverAddress,
        null,
        null,
        forwardAmount,
        forwardPayloadSlice,
        { value: grams("0.05"), bounce: true },
    );

    expect(result).toHaveSuccessfulTx<ChangeWalletOwner>({
        from: nftOwner.address,
        to: nftItem.address,
    });

    expect(result).toHaveTx<NotificationForNewOwner>({
        from: nftItem.address,
        to: nftReceiverAddress,
        bounce: false,
    });

    val ownerAfterTransfer = nftItem.getNftData().ownerAddress;
    expect(ownerAfterTransfer!).toEqual(nftReceiverAddress);
}

get fun `test nft: should fail with an incomplete transfer body`() {
    val (nftCollection, _, _) = setupTest();
    val nftOwner = testing.treasury("nft-owner");

    val nftItem = nftFixture(nftCollection, nftOwner.address);

    val ownerBeforeTransfer = nftItem.getNftData().ownerAddress;
    expect(ownerBeforeTransfer!).toEqual(nftOwner.address);

    // a transfer body with only queryId: new_owner and the next fields are missing
    val body = beginCell()
        .storeUint(0x5fcc3d14, 32) // op::transfer
        .storeUint(42, 64) // queryId
        .endCell();

    val result = nftItem.sendAny(nftOwner.address, body, { value: grams("0.05"), bounce: true });

    expect(result).toHaveFailedTx({
        from: nftOwner.address,
        to: nftItem.address,
        body,
        exitCode: 9, // cell underflow
    });

    val ownerAfterTransfer = nftItem.getNftData().ownerAddress;
    expect(ownerAfterTransfer!).toEqual(ownerBeforeTransfer!);
}

/// AgenticCollection has no batch deploy, so the test deploys the same 100 wallets one by one.
get fun `test nft: bench should deploy 100 wallets one by one`() {
    val (nftCollection, deployer, _) = setupTest();
    val ownerAddress = randomAddress("ownerAddress");
    val content = beginCell().storeString("Content").endCell();

    var i = 0;
    while (i < 100) {
        val nftDeployResult = deployWallet(
            nftCollection,
            deployer.address,
            null,
            walletInitParams(ownerAddress, content),
            grams("0.02"),
            grams("0.05"),
        );

        expect(nftDeployResult).toHaveSuccessfulTx<RelayDeployWallet>({
            from: deployer.address,
            to: nftCollection.address,
        });

        expect(nftDeployResult).toHaveSuccessfulDeploy({
            from: nftCollection.address,
            to: nftCollection.getNftAddressByIndex(i),
        });

        i += 1;
    }

    val newNextItemIndex = nftCollection.getCollectionData().nextWalletIndex;
    expect(newNextItemIndex).toEqual(100);
}
