import "@stdlib/strings"

import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/array"

import "@contracts/errors"
import "@contracts/messages"
import "@tests/fixtures"
import "@wrappers/AgenticCollection.gen"
import "@wrappers/AgenticWallet.gen"

get fun `test nft: should report royalty params`() {
    val (nftCollection, _, royaltyParams) = setupTest();
    val randomTreasury = testing.treasury("random treasury");
    val queryId = 42;
    val result = nftCollection.sendRequestRoyaltyParams(
        randomTreasury.address,
        queryId,
        { value: grams("0.05") },
    );

    expect(result).toHaveSuccessfulTx<RequestRoyaltyParams>({
        from: randomTreasury.address,
        to: nftCollection.address,
    });

    expect(result).toHaveTx<ResponseRoyaltyParams>({
        from: nftCollection.address,
        to: randomTreasury.address,
        bounce: false,
        body: ResponseRoyaltyParams { queryId, royaltyParams }.toCell(),
    });
}

fun shouldNotAllowAnyOtherOpcodeNotFromOwner(opcode: int) {
    val randomTreasury = testing.treasury("random-treasury");

    // one collection per opcode
    val royaltyName = StringBuilder.create().append("royalty-").appendInt(opcode).build();
    val (nftCollection, _, _) = setupTest(grams("0.05"), royaltyName);

    val result = nftCollection.sendAny(
        randomTreasury.address,
        beginCell().storeUint(opcode, 32).storeUint(42, 64).endCell(),
        { value: grams("0.05") },
    );

    val exitCode = opcode == 0x042 ? 0xFFFF : Errors.NotFromAdmin as int;

    expect(result).toHaveTx({
        from: randomTreasury.address,
        to: nftCollection.address,
        opcode,
        success: false,
        exitCode,
    });
}

get fun `test nft: should reject admin and unknown opcodes from a non-admin`() {
    [
        0xdb6169ee, // RelayDeployWallet
        0x3d0bfff2, // RelayEditWalletContent
        0x2f48d4a1, // ChangeCollectionAdmin
        0xf30285b3, // EditCollectionContent
        0xddf389ab, // WithdrawCollectionBalance
        0x42,
    ].each(shouldNotAllowAnyOtherOpcodeNotFromOwner);
}

get fun `test nft: should deploy a wallet`() {
    val (nftCollection, deployer, _) = setupTest();
    val nextItemIndex = nftCollection.getCollectionData().nextWalletIndex;
    val ownerAddress = randomAddress("ownerAddress");
    val content = beginCell().storeString("Content").endCell();

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

    val nftAddress = nftCollection.getNftAddressByIndex(nextItemIndex);

    expect(nftDeployResult).toHaveSuccessfulDeploy({
        from: nftCollection.address,
        to: nftAddress,
    });

    val nftItem = AgenticWallet.fromAddress(nftAddress);
    val data = nftItem.getNftData();

    expect(data.isInitialized).toBeTrue();
    expect(data.walletIndex).toEqual(nextItemIndex);
    expect(data.ownerAddress!).toEqual(ownerAddress);
    expect(data.collectionAddress).toEqual(nftCollection.address);
    expect(data.content!).toEqual(content);
}

get fun `test nft: should reject a deploy at an invalid wallet index`() {
    val (nftCollection, deployer, _) = setupTest();
    val nextItemIndex = nftCollection.getCollectionData().nextWalletIndex;

    val nftDeployResult = deployWallet(
        nftCollection,
        deployer.address,
        nextItemIndex + 1, // one past the next index
        walletInitParams(deployer.address, createEmptyCell()),
        grams("0.02"),
        grams("0.05"),
    );

    expect(nftDeployResult).toHaveFailedTx<RelayDeployWallet>({
        from: deployer.address,
        to: nftCollection.address,
        exitCode: Errors.InvalidWalletIndex,
    });
}

get fun `test nft: a deploy at the next index should increment it`() {
    val (nftCollection, deployer, _) = setupTest();
    val nextItemIndex = nftCollection.getCollectionData().nextWalletIndex;

    val nftDeployResult = deployWallet(
        nftCollection,
        deployer.address,
        null,
        walletInitParams(deployer.address, createEmptyCell()),
        grams("0.02"),
        grams("0.05"),
    );

    expect(nftDeployResult).toHaveSuccessfulTx<RelayDeployWallet>({
        from: deployer.address,
        to: nftCollection.address,
    });

    val newNextItemIndex = nftCollection.getCollectionData().nextWalletIndex;
    expect(newNextItemIndex).toEqual(nextItemIndex + 1);
}

get fun `test nft: a redeploy below the next index should not increment it`() {
    val (nftCollection, deployer, _) = setupTest();
    val nextItemIndex = nftCollection.getCollectionData().nextWalletIndex;

    // deploy the first wallet at index 0
    deployWallet(
        nftCollection,
        deployer.address,
        null,
        walletInitParams(deployer.address, createEmptyCell()),
        grams("0.02"),
        grams("0.05"),
    );

    val newNextItemIndex = nftCollection.getCollectionData().nextWalletIndex;
    expect(newNextItemIndex).toEqual(nextItemIndex + 1);

    // deploy index 0 again: a redeploy below the next index
    val nftDeployResult = deployWallet(
        nftCollection,
        deployer.address,
        0,
        walletInitParams(deployer.address, createEmptyCell()),
        grams("0.02"),
        grams("0.05"),
    );

    expect(nftDeployResult).toHaveSuccessfulTx<RelayDeployWallet>({
        from: deployer.address,
        to: nftCollection.address,
    });

    val newNextItemIndexAfterSecondDeploy = nftCollection.getCollectionData().nextWalletIndex;
    expect(newNextItemIndexAfterSecondDeploy).toEqual(newNextItemIndex);
}

/// AgenticCollection has no batch deploy, so the test deploys the same wallets one by one.
get fun `test nft: should deploy several wallets one by one`() {
    val (nftCollection, deployer, _) = setupTest();
    val nextItemIndex: int = nftCollection.getCollectionData().nextWalletIndex;
    val ownerAddress = randomAddress("ownerAddress");
    val content = beginCell().storeString("Content").endCell();

    val indexes = [nextItemIndex, nextItemIndex + 1, nextItemIndex + 2];

    var i = 0;
    while (i < 3) {
        val index = indexes.get(i);
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
            to: nftCollection.getNftAddressByIndex(index),
        });

        i += 1;
    }

    i = 0;
    while (i < 3) {
        val index = indexes.get(i);
        val nftAddress = nftCollection.getNftAddressByIndex(index);

        val nftItem = AgenticWallet.fromAddress(nftAddress);
        val data = nftItem.getNftData();

        expect(data.isInitialized).toBeTrue();
        expect(data.walletIndex).toEqual(index);
        expect(data.ownerAddress!).toEqual(ownerAddress);
        expect(data.collectionAddress).toEqual(nftCollection.address);
        expect(data.content!).toEqual(content);

        i += 1;
    }
}

get fun `test nft: should change the admin`() {
    val (nftCollection, deployer, _) = setupTest();
    val oldOwnerAddress = nftCollection.getCollectionData().adminAddress;
    val newOwner = testing.treasury("new-owner");

    val result = nftCollection.sendChangeCollectionAdmin(
        deployer.address,
        0,
        newOwner.address,
        { value: grams("0.05"), bounce: true },
    );

    expect(result).toHaveSuccessfulTx<ChangeCollectionAdmin>({
        from: deployer.address,
        to: nftCollection.address,
    });

    val newOwnerAddress = nftCollection.getCollectionData().adminAddress;

    expect(oldOwnerAddress).toNotEqual(newOwnerAddress);
    expect(newOwnerAddress).toEqual(newOwner.address);
}
