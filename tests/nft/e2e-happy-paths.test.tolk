import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/fees"
import "@contracts/messages"
import "@contracts/storage"
import "@contracts/storage-collection"
import "@tests/fixtures"
import "@tests/utils"
import "@wrappers/AgenticCollection.gen"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/send"
import "@wrappers/utils"

const NFT_E2E_NOW = 1000
const NFT_E2E_ROYALTY_QUERY_ID = 7301
const NFT_E2E_DEPLOY_QUERY_ID = 7302
const NFT_E2E_TRANSFER_QUERY_ID = 7303
const NFT_E2E_STATIC_QUERY_ID = 7304
const NFT_E2E_SEVERAL_QUERY_ID = 7305
const NFT_E2E_CHANGE_ADMIN_QUERY_ID = 7306
const NFT_E2E_EDIT_WALLET_QUERY_ID = 7307
const NFT_E2E_EDIT_COLLECTION_QUERY_ID = 7308
const NFT_E2E_WITHDRAW_QUERY_ID = 7309
const NFT_E2E_EDIT_SETTINGS_QUERY_ID = 7310
const NFT_E2E_PUBLIC_DEPLOY_QUERY_ID = 7311

const NFT_E2E_TRANSFER_VALUE = grams("0.12")
const NFT_E2E_FORWARD_AMOUNT = grams("0.01")
const NFT_E2E_SEVERAL_COUNT = 4
const NFT_E2E_FORWARD_MARKER = 0x4e465431

const NFT_E2E_COMMON_CONTENT = "ipfs://nft-e2e/"
const NFT_E2E_SINGLE_CONTENT = "single.json"
const NFT_E2E_SEVERAL_CONTENT = "several.json"
const NFT_E2E_EDITED_CONTENT = "edited.json"
const NFT_E2E_EDITED_COMMON_CONTENT = "ipfs://nft-e2e-edited/"

struct NftE2eContext {
    collection: AgenticCollection
    deployer: Treasury
    royaltyReader: Treasury
    royaltyRecipient: Treasury
    itemOwner: Treasury
    itemReceiver: Treasury
    excessesReceiver: Treasury
    staticReader: Treasury
    severalOwner: Treasury
    newAdmin: Treasury
    royaltyParams: RoyaltyParams
}

struct NftE2eItemFixture {
    ctx: NftE2eContext
    item: AgenticWallet
    itemIndex: int
}

fun makeE2eContent(content: string): cell {
    return beginCell().storeString(content).endCell();
}

fun makeE2eCollectionMetadata(): cell {
    return beginCell().storeSlice("nft-e2e-collection".beginParse()).endCell();
}

fun deployCollectionStage(): NftE2eContext {
    testing.setNow(NFT_E2E_NOW);

    val deployer = testing.treasury("nft-e2e-deployer");
    val royaltyReader = testing.treasury("nft-e2e-royalty-reader");
    val royaltyRecipient = testing.treasury("nft-e2e-royalty-recipient");
    val itemOwner = testing.treasury("nft-e2e-item-owner");
    val itemReceiver = testing.treasury("nft-e2e-item-receiver");
    val excessesReceiver = testing.treasury("nft-e2e-excesses-receiver");
    val staticReader = testing.treasury("nft-e2e-static-reader");
    val severalOwner = testing.treasury("nft-e2e-several-owner");
    val newAdmin = testing.treasury("nft-e2e-new-admin");

    val royaltyParams = RoyaltyParams {
        numerator: 5,
        denominator: 100,
        royaltyAddress: royaltyRecipient.address,
    };
    val collection = AgenticCollection.fromStorage(
        AgenticCollectionStorage.create(
            deployer.address,
            blockchain.globalId(),
            build("AgenticWallet"),
            {
                collectionMetadata: makeE2eCollectionMetadata(),
                commonContent: NFT_E2E_COMMON_CONTENT,
            },
            royaltyParams,
            {
                maxWalletIndex: MAX_WALLET_INDEX_UNLIMITED,
                publicDeployEnabled: true,
                deployPrice: TEST_DEPLOY_PRICE,
                referralBps: TEST_REFERRAL_BPS,
                traitSetCount: TEST_TRAIT_SET_COUNT,
            },
        ),
    );

    val deploy = collection.deploy(deployer.address, { value: grams("1"), bounce: false });
    deploy.giveName("deploy collection");
    expect(deploy).toHaveSuccessfulDeploy({ to: collection.address });

    val data = collection.getCollectionData();
    expect(data.nextWalletIndex).toEqual(0);
    expect(data.adminAddress).toEqual(deployer.address);

    return {
        collection,
        deployer,
        royaltyReader,
        royaltyRecipient,
        itemOwner,
        itemReceiver,
        excessesReceiver,
        staticReader,
        severalOwner,
        newAdmin,
        royaltyParams,
    };
}

fun reportRoyaltyParamsStage(ctx: NftE2eContext) {
    val report = ctx
        .collection
        .sendRequestRoyaltyParams(
            ctx.royaltyReader.address,
            NFT_E2E_ROYALTY_QUERY_ID,
            { value: grams("0.05"), bounce: true },
        );
    report.giveName("report royalty params");

    expect(report).toHaveSuccessfulTx<RequestRoyaltyParams>({
        from: ctx.royaltyReader.address,
        to: ctx.collection.address,
    });
    expect(report).toHaveTx<ResponseRoyaltyParams>({
        from: ctx.collection.address,
        to: ctx.royaltyReader.address,
        bounce: false,
        body: ResponseRoyaltyParams {
            queryId: NFT_E2E_ROYALTY_QUERY_ID,
            royaltyParams: ctx.royaltyParams,
        }.toCell(),
    });
    expect(ctx.collection.royaltyParams()).toEqual(ctx.royaltyParams);
}

/// Anyone deploys the next wallet. The referrer gets its share of the price.
fun publicDeployWithReferralStage(ctx: NftE2eContext) {
    val requester = testing.treasury("nft-e2e-public-requester");
    val referrer = randomAddress("nft-e2e-referrer");
    val walletIndex = ctx.collection.getCollectionData().nextWalletIndex;
    val walletAddress = ctx.collection.getNftAddressByIndex(walletIndex);
    val emptyPayload = emptyForwardPayload();

    val deploy = ctx
        .collection
        .sendRelayPublicDeployWallet(
            requester.address,
            NFT_E2E_PUBLIC_DEPLOY_QUERY_ID,
            referrer,
            { value: TEST_DEPLOY_VALUE, bounce: true },
        );
    deploy.giveName("public deploy wallet with referral");
    expect(deploy).toHaveSuccessfulTx<RelayPublicDeployWallet>({
        from: requester.address,
        to: ctx.collection.address,
    });
    expect(deploy).toHaveSuccessfulDeploy({ from: ctx.collection.address, to: walletAddress });
    expect(deploy).toHaveTx({
        from: ctx.collection.address,
        to: referrer,
        bounce: false,
        value: TEST_DEPLOY_PRICE * TEST_REFERRAL_BPS / REFERRAL_BPS_DENOMINATOR,
    });
    expect(deploy).toHaveTx<NotificationForNewOwner>({
        from: walletAddress,
        to: requester.address,
        value: MIN_FORWARD_AMOUNT,
        body: NotificationForNewOwner {
            queryId: NFT_E2E_PUBLIC_DEPLOY_QUERY_ID,
            oldOwnerAddress: ctx.collection.address,
            forwardPayload: emptyPayload.toCell().beginParse(),
        }.toCell(),
    });
    expect(ctx.collection.getCollectionData().nextWalletIndex).toEqual(walletIndex + 1);
}

fun deploySingleNftStage(ctx: NftE2eContext, expectedIndex: int): NftE2eItemFixture {
    val nextItemIndex = ctx.collection.getCollectionData().nextWalletIndex;
    expect(nextItemIndex).toEqual(expectedIndex);

    val deploy = ctx
        .collection
        .sendRelayDeployWallet(
            ctx.deployer.address,
            NFT_E2E_DEPLOY_QUERY_ID,
            null,
            TEST_WALLET_ATTACH_AMOUNT,
            walletInitParams(ctx.itemOwner.address, makeE2eContent(NFT_E2E_SINGLE_CONTENT)),
            { value: TEST_WALLET_DEPLOY_VALUE, bounce: true },
        );
    deploy.giveName("deploy wallet");
    expect(deploy).toHaveSuccessfulTx<RelayDeployWallet>({
        from: ctx.deployer.address,
        to: ctx.collection.address,
    });

    val nftAddress = ctx.collection.getNftAddressByIndex(nextItemIndex);
    expect(deploy).toHaveSuccessfulDeploy({
        from: ctx.collection.address,
        to: nftAddress,
    });

    val item = AgenticWallet.fromAddress(nftAddress);
    val data = item.getNftData();
    expect(data.isInitialized).toBeTrue();
    expect(data.walletIndex).toEqual(nextItemIndex);
    expect(data.ownerAddress!).toEqual(ctx.itemOwner.address);
    expect(data.collectionAddress).toEqual(ctx.collection.address);
    expect(data.content!).toEqual(makeE2eContent(NFT_E2E_SINGLE_CONTENT));
    expect(ctx.collection.getCollectionData().nextWalletIndex).toEqual(nextItemIndex + 1);

    return {
        ctx,
        item,
        itemIndex: nextItemIndex,
    };
}

fun transferNftStage(fixture: NftE2eItemFixture) {
    val forwardPayload = beginCell()
        .storeUint(NFT_E2E_FORWARD_MARKER, 32)
        .storeSlice("nft-e2e-transfer".beginParse())
        .endCell();
    val transfer = fixture
        .item
        .sendChangeWalletOwnerPayloadInRef(
            fixture.ctx.itemOwner.address,
            NFT_E2E_TRANSFER_QUERY_ID,
            fixture.ctx.itemReceiver.address,
            fixture.ctx.excessesReceiver.address,
            null,
            NFT_E2E_FORWARD_AMOUNT,
            forwardPayload,
            { value: NFT_E2E_TRANSFER_VALUE, bounce: true },
        );

    transfer.giveName("transfer wallet");
    expect(transfer).toHaveSuccessfulTx<ChangeWalletOwner>({
        from: fixture.ctx.itemOwner.address,
        to: fixture.item.address,
    });
    expect(transfer).toHaveTx<NotificationForNewOwner>({
        from: fixture.item.address,
        to: fixture.ctx.itemReceiver.address,
        value: NFT_E2E_FORWARD_AMOUNT,
        bounce: false,
    });
    expect(transfer).toHaveTx<ReturnExcessesBack>({
        from: fixture.item.address,
        to: fixture.ctx.excessesReceiver.address,
        bounce: false,
    });

    val data = fixture.item.getNftData();
    expect(data.ownerAddress!).toEqual(fixture.ctx.itemReceiver.address);
}

fun requestStaticDataStage(fixture: NftE2eItemFixture) {
    val data = fixture.item.getNftData();
    val report = fixture
        .item
        .sendRequestStaticData(
            fixture.ctx.staticReader.address,
            NFT_E2E_STATIC_QUERY_ID,
            { value: grams("0.05"), bounce: true },
        );
    report.giveName("request static data");

    expect(report).toHaveSuccessfulTx<RequestStaticData>({
        from: fixture.ctx.staticReader.address,
        to: fixture.item.address,
    });
    expect(report).toHaveTx<ResponseStaticData>({
        from: fixture.item.address,
        to: fixture.ctx.staticReader.address,
        bounce: false,
        body: ResponseStaticData {
            queryId: NFT_E2E_STATIC_QUERY_ID,
            walletIndex: data.walletIndex as uint256,
            collectionAddress: data.collectionAddress,
        }.toCell(),
    });
}

/// AgenticCollection has no batch deploy, so this stage deploys the same wallets one by one.
/// Then it changes the admin.
fun mintSeveralAndChangeAdminStage(ctx: NftE2eContext, expectedFirstIndex: int) {
    val firstIndex = ctx.collection.getCollectionData().nextWalletIndex;
    expect(firstIndex).toEqual(expectedFirstIndex);

    var i = 0;
    while (i < NFT_E2E_SEVERAL_COUNT) {
        val deploy = ctx
            .collection
            .sendRelayDeployWallet(
                ctx.deployer.address,
                NFT_E2E_SEVERAL_QUERY_ID,
                null,
                TEST_WALLET_ATTACH_AMOUNT,
                walletInitParams(ctx.severalOwner.address, makeE2eContent(NFT_E2E_SEVERAL_CONTENT)),
                { value: TEST_WALLET_DEPLOY_VALUE, bounce: true },
            );
        deploy.giveName("deploy several wallets");
        expect(deploy).toHaveSuccessfulTx<RelayDeployWallet>({
            from: ctx.deployer.address,
            to: ctx.collection.address,
        });
        expect(deploy).toHaveSuccessfulDeploy({
            from: ctx.collection.address,
            to: ctx.collection.getNftAddressByIndex(firstIndex + i),
        });
        i += 1;
    }

    val firstAddress = ctx.collection.getNftAddressByIndex(firstIndex);
    val lastIndex = firstIndex + NFT_E2E_SEVERAL_COUNT - 1;
    val lastAddress = ctx.collection.getNftAddressByIndex(lastIndex);

    val firstItem = AgenticWallet.fromAddress(firstAddress);
    val lastItem = AgenticWallet.fromAddress(lastAddress);
    expect(firstItem.getNftData().ownerAddress!).toEqual(ctx.severalOwner.address);
    expect(lastItem.getNftData().ownerAddress!).toEqual(ctx.severalOwner.address);
    expect(ctx.collection.getCollectionData().nextWalletIndex).toEqual(
        firstIndex + NFT_E2E_SEVERAL_COUNT,
    );

    val changeAdmin = ctx
        .collection
        .sendChangeCollectionAdmin(
            ctx.deployer.address,
            NFT_E2E_CHANGE_ADMIN_QUERY_ID,
            ctx.newAdmin.address,
            { value: grams("0.05"), bounce: true },
        );
    changeAdmin.giveName("change collection admin");
    expect(changeAdmin).toHaveSuccessfulTx<ChangeCollectionAdmin>({
        from: ctx.deployer.address,
        to: ctx.collection.address,
    });
    expect(ctx.collection.getCollectionData().adminAddress).toEqual(ctx.newAdmin.address);
}

/// Collection operations that stages 1-4 do not reach: a top-up, then admin operations from
/// `newAdmin`. This stage runs after the admin change.
fun topUpEditAndWithdrawStage(fixture: NftE2eItemFixture) {
    val ctx = fixture.ctx;

    val topUp = ctx
        .collection
        .sendAny(ctx.deployer.address, createEmptyCell(), { value: grams("1"), bounce: false });
    topUp.giveName("top up collection");
    expect(topUp).toHaveSuccessfulTx({ from: ctx.deployer.address, to: ctx.collection.address });

    val editWallet = ctx
        .collection
        .sendRelayEditWalletContent(
            ctx.newAdmin.address,
            NFT_E2E_EDIT_WALLET_QUERY_ID,
            fixture.itemIndex,
            makeE2eContent(NFT_E2E_EDITED_CONTENT),
            { value: grams("0.05"), bounce: true },
        );
    editWallet.giveName("edit wallet content");
    expect(editWallet).toHaveSuccessfulTx<RelayEditWalletContent>({
        from: ctx.newAdmin.address,
        to: ctx.collection.address,
    });
    expect(editWallet).toHaveSuccessfulTx<EditWalletContent>({
        from: ctx.collection.address,
        to: fixture.item.address,
    });
    expect(fixture.item.getNftData().content!).toEqual(makeE2eContent(NFT_E2E_EDITED_CONTENT));

    val newRoyaltyParams = RoyaltyParams {
        numerator: 7,
        denominator: 100,
        royaltyAddress: ctx.royaltyRecipient.address,
    };
    val editCollection = ctx
        .collection
        .sendEditCollectionContent(
            ctx.newAdmin.address,
            NFT_E2E_EDIT_COLLECTION_QUERY_ID,
            {
                collectionMetadata: makeE2eCollectionMetadata(),
                commonContent: NFT_E2E_EDITED_COMMON_CONTENT,
            },
            newRoyaltyParams,
            { value: grams("0.05"), bounce: true },
        );
    editCollection.giveName("edit collection content");
    expect(editCollection).toHaveSuccessfulTx<EditCollectionContent>({
        from: ctx.newAdmin.address,
        to: ctx.collection.address,
    });
    expect(ctx.collection.royaltyParams()).toEqual(newRoyaltyParams);

    // stops new deploys after the last deployed index
    val lastMintedIndex = ctx.collection.getCollectionData().nextWalletIndex - 1;
    val editSettings = ctx
        .collection
        .sendEditCollectionSettings(
            ctx.newAdmin.address,
            NFT_E2E_EDIT_SETTINGS_QUERY_ID,
            lastMintedIndex,
            false,
            TEST_DEPLOY_PRICE,
            TEST_REFERRAL_BPS,
            TEST_TRAIT_SET_COUNT,
            { value: grams("0.05"), bounce: true },
        );
    editSettings.giveName("edit collection settings");
    expect(editSettings).toHaveSuccessfulTx<EditCollectionSettings>({
        from: ctx.newAdmin.address,
        to: ctx.collection.address,
    });
    expect(ctx.collection.getCollectionSettings().maxWalletIndex).toEqual(lastMintedIndex);
    expect(ctx.collection.getCollectionSettings().publicDeployEnabled).toBeFalse();

    val withdraw = ctx
        .collection
        .sendWithdrawCollectionBalance(
            ctx.newAdmin.address,
            NFT_E2E_WITHDRAW_QUERY_ID,
            { value: grams("0.05"), bounce: true },
        );
    withdraw.giveName("withdraw collection balance");
    expect(withdraw).toHaveSuccessfulTx<WithdrawCollectionBalance>({
        from: ctx.newAdmin.address,
        to: ctx.collection.address,
    });
    expect(withdraw).toHaveTx<WithdrawCollectionBalance>({
        from: ctx.collection.address,
        to: ctx.newAdmin.address,
        bounce: true,
        body: WithdrawCollectionBalance { queryId: NFT_E2E_WITHDRAW_QUERY_ID }.toCell(),
    });
    expect(testing.getAccountBalance(ctx.collection.address)).toEqual(MIN_COLLECTION_STORAGE);
}

get fun `test nft e2e bench: stage 1 deploy collection`() {
    deployCollectionStage();
}

get fun `test nft e2e bench: stage 2 report royalty params`() {
    val ctx = deployCollectionStage();
    reportRoyaltyParamsStage(ctx);
}

get fun `test nft e2e bench: stage 3 deploy wallet`() {
    val ctx = deployCollectionStage();
    reportRoyaltyParamsStage(ctx);
    deploySingleNftStage(ctx, 0);
}

get fun `test nft e2e bench: stage 4 transfer wallet and request static data`() {
    val ctx = deployCollectionStage();
    reportRoyaltyParamsStage(ctx);
    val fixture = deploySingleNftStage(ctx, 0);
    transferNftStage(fixture);
    requestStaticDataStage(fixture);
}

get fun `test nft e2e bench: stage 5 full collection and wallet flow`() {
    val ctx = deployCollectionStage();
    reportRoyaltyParamsStage(ctx);
    // the public deploy takes index 0
    publicDeployWithReferralStage(ctx);
    val fixture = deploySingleNftStage(ctx, 1);
    transferNftStage(fixture);
    requestStaticDataStage(fixture);
    mintSeveralAndChangeAdminStage(ctx, 2);
    topUpEditAndWithdrawStage(fixture);
}
