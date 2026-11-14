import "@stdlib/strings"

import "@acton/build"
import "@acton/fmt"
import "@acton/emulation/config"

import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/errors"
import "@contracts/fees"
import "@contracts/messages"
import "@contracts/storage"
import "@contracts/storage-collection"
import "@contracts/wallet-content"
import "@tests/fixtures"
import "@tests/utils"
import "@wrappers/AgenticCollection.gen"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/send"
import "@wrappers/utils"

/// All values that the collection getters return. They are the same before and after a rejected
/// message.
struct CollectionSnapshot {
    data: CollectionDataReply
    royaltyParams: RoyaltyParams
    settings: CollectionSettingsReply
}

fun snapshot(collection: AgenticCollection): CollectionSnapshot {
    return {
        data: collection.getCollectionData(),
        royaltyParams: collection.royaltyParams(),
        settings: collection.getCollectionSettings(),
    };
}

fun editSettings(
    collection: AgenticCollection,
    sender: address,
    maxWalletIndex: uint64,
    publicDeployEnabled: bool = true,
    deployPrice: coins = TEST_DEPLOY_PRICE,
    referralBps: uint16 = TEST_REFERRAL_BPS,
    traitSetCount: uint16 = TEST_TRAIT_SET_COUNT,
): SendResultList {
    return collection.sendEditCollectionSettings(
        sender,
        0,
        maxWalletIndex,
        publicDeployEnabled,
        deployPrice,
        referralBps,
        traitSetCount,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
}

/// Deploys the next wallet for `sender` with `RelayPublicDeployWallet`.
fun publicDeploy(
    collection: AgenticCollection,
    sender: address,
    referralAddress: address?,
    value: coins,
): SendResultList {
    return collection.sendRelayPublicDeployWallet(
        sender,
        0,
        referralAddress,
        { value, bounce: true },
    );
}

/// An empty forward payload has no Either bit, so the wallet rejects the deploy.
fun invalidInitParams(ownerAddress: address): AgenticWalletInitParams {
    return {
        ownerAddress,
        content: createEmptyCell(),
        delegatePublicKey: 0,
        forwardAmount: 0,
        forwardPayload: createEmptySlice(),
    };
}

fun expectWalletLimitReached(result: SendResultList, from: address, to: address) {
    expect(result).toHaveFailedTx({
        from,
        to,
        exitCode: Errors.WalletLimitReached,
    });
    expect(result).toNotHaveTx({ from: to, deploy: true });
}

fun newCollectionContent(): CollectionContent {
    return {
        collectionMetadata: beginCell().storeString("new metadata").endCell(),
        commonContent: "https://example.com/agents/",
    };
}

fun newRoyaltyParams(): RoyaltyParams {
    return {
        numerator: 3,
        denominator: 100,
        royaltyAddress: randomAddress("newRoyaltyAddress"),
    };
}

/// Reads off-chain content from `get_nft_content`: a 0x01 byte and a ref with the URL.
fun offchainUrl(content: cell): string {
    val s = content.beginParse();
    expect(s.preloadUint(8)).toEqual(0x01);
    return s.preloadRef() as unknown as string;
}

get fun `test collection: admin should edit content and royalty params`() {
    val (collection, admin, _) = setupTest();
    val content = newCollectionContent();
    val royaltyParams = newRoyaltyParams();

    val result = collection.sendEditCollectionContent(
        admin.address,
        0,
        content,
        royaltyParams,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveSuccessfulTx<EditCollectionContent>({
        from: admin.address,
        to: collection.address,
    });
    expect(collection.getCollectionData().collectionMetadata).toEqual(content.collectionMetadata);
    expect(collection.royaltyParams()).toEqual(royaltyParams);
    expect(
        offchainUrl(
            collection.getNftContent(7, WalletIndexContent {}.toCell()),
        ).equalTo("https://example.com/agents/7.json"),
    ).toBeTrue();
}

get fun `test collection: should reject a content edit from a non-admin`() {
    val (collection, _, _) = setupTest();
    val notAdmin = testing.treasury("not-admin");
    val before = snapshot(collection);

    val result = collection.sendEditCollectionContent(
        notAdmin.address,
        0,
        newCollectionContent(),
        newRoyaltyParams(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveFailedTx<EditCollectionContent>({
        from: notAdmin.address,
        to: collection.address,
        exitCode: Errors.NotFromAdmin,
    });
    expect(snapshot(collection)).toEqual(before);
}

get fun `test collection: admin should withdraw balance above storage minimum`() {
    val (collection, admin, _) = setupTest();
    val queryId = 42;
    testing.topUp(collection.address, grams("1"));

    val result = collection.sendWithdrawCollectionBalance(
        admin.address,
        queryId,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveSuccessfulTx<WithdrawCollectionBalance>({
        from: admin.address,
        to: collection.address,
    });
    expect(result).toHaveTx<WithdrawCollectionBalance>({
        from: collection.address,
        to: admin.address,
        bounce: true,
        value: fun(v) {
            return v > grams("1");
        },
        body: WithdrawCollectionBalance { queryId }.toCell(),
    });
    expect(testing.getAccountBalance(collection.address)).toEqual(MIN_COLLECTION_STORAGE);
}

get fun `test collection: should reject a withdrawal from a non-admin`() {
    val (collection, _, _) = setupTest();
    val notAdmin = testing.treasury("not-admin");
    testing.topUp(collection.address, grams("1"));
    val balanceBefore = testing.getAccountBalance(collection.address);

    val result = collection.sendWithdrawCollectionBalance(
        notAdmin.address,
        0,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveFailedTx<WithdrawCollectionBalance>({
        from: notAdmin.address,
        to: collection.address,
        exitCode: Errors.NotFromAdmin,
    });
    expect(result).toNotHaveTx<WithdrawCollectionBalance>({ from: collection.address });
    expect(testing.getAccountBalance(collection.address)).toBeGreaterOrEqual(balanceBefore);
}

get fun `test collection: withdraw should fail below storage minimum`() {
    val (collection, admin, _) = setupTest(MIN_COLLECTION_STORAGE / 2);
    expect(testing.getAccountBalance(collection.address)).toBeLess(MIN_COLLECTION_STORAGE);

    val result = collection.sendWithdrawCollectionBalance(
        admin.address,
        0,
        { value: MIN_COLLECTION_STORAGE / 2, bounce: true },
    );

    expect(result).toHaveTx<WithdrawCollectionBalance>({
        from: admin.address,
        to: collection.address,
        exitCode: 0,
        success: false,
        actionExitCode: fun(code) {
            return code != 0;
        },
    });
    expect(result).toHaveTx({ from: collection.address, to: admin.address, bounced: true });
    expect(result).toNotHaveTx<WithdrawCollectionBalance>({ from: collection.address });
}

/// A 5 GRAM deploy at a 3 GRAM price leaves the wallet 2 GRAM and the collection under 3 GRAM.
get fun `test public deploy: should deploy the wallet with the value left after the price`() {
    val (collection, _, _) = setupTest(
        TEST_COLLECTION_DEPLOY_VALUE,
        "royaltyAddress",
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        grams("3"),
    );
    val requester = testing.treasury("requester");
    val walletAddress = collection.getNftAddressByIndex(0);
    val collectionBefore = testing.getAccountBalance(collection.address);

    val result = publicDeploy(collection, requester.address, null, grams("5"));

    expect(result).toHaveSuccessfulTx<RelayPublicDeployWallet>({
        from: requester.address,
        to: collection.address,
    });
    expect(result).toHaveSuccessfulDeploy({ from: collection.address, to: walletAddress });
    expect(result).toHaveTx<NotificationForNewOwner>({
        from: walletAddress,
        to: requester.address,
        value: MIN_FORWARD_AMOUNT,
        bounce: false,
        body: NotificationForNewOwner {
            queryId: 0,
            oldOwnerAddress: collection.address,
            forwardPayload: emptyForwardPayload().toCell().beginParse(),
        }.toCell(),
    });
    // no referral: the collection sends only the deploy
    expect(result).toNotHaveTx({ from: collection.address, to: requester.address });

    val wallet = AgenticWallet.fromAddress(walletAddress);
    val data = wallet.getNftData();
    expect(data.ownerAddress!).toEqual(requester.address);
    val content = TraitSetContent.fromCell(data.content!);
    expect(content.traitSetIndex).toBeLess(TEST_TRAIT_SET_COUNT);
    expect(wallet.getPublicKey()).toEqual(0);
    val walletBalance = testing.getAccountBalance(walletAddress);
    expect(walletBalance).toBeGreaterOrEqual(grams("2"));
    expect(walletBalance).toBeLess(grams("2") + WALLET_DEPLOY_FEES);

    val collectionDiff = testing.getAccountBalance(collection.address) - collectionBefore;
    // the collection pays the wallet gas and its own fees from the price
    expect(collectionDiff).toBeGreater(grams("2.99"));
    expect(collectionDiff).toBeLess(grams("3") - WALLET_DEPLOY_FEES);
    expect(collection.getCollectionData().nextWalletIndex).toEqual(1);
}

/// The reward is a share of the price, not of the value.
get fun `test public deploy: should pay the referral share of the price`() {
    val (collection, _, _) = setupTest(
        TEST_COLLECTION_DEPLOY_VALUE,
        "royaltyAddress",
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        grams("3"),
        1000,
    );
    val requester = testing.treasury("requester");
    val referrer = randomAddress("referrer");
    val collectionBefore = testing.getAccountBalance(collection.address);

    val result = publicDeploy(collection, requester.address, referrer, grams("5"));

    expect(result).toHaveSuccessfulDeploy({
        from: collection.address,
        to: collection.getNftAddressByIndex(0),
    });
    expect(result).toHaveTx({
        from: collection.address,
        to: referrer,
        value: grams("0.3"),
        bounce: false,
        body: TextComment { text: "Referral reward".literalSlice() }.toCell(),
    });
    expect(testing.getAccountBalance(collection.getNftAddressByIndex(0))).toBeGreaterOrEqual(
        grams("2"),
    );
    val collectionDiff = testing.getAccountBalance(collection.address) - collectionBefore;
    expect(collectionDiff).toBeGreater(grams("2.69"));
    expect(collectionDiff).toBeLess(grams("2.7") - WALLET_DEPLOY_FEES);
}

get fun `test public deploy: should round the referral reward down`() {
    val (collection, _, _) = setupTest(
        TEST_COLLECTION_DEPLOY_VALUE,
        "royaltyAddress",
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        TEST_DEPLOY_PRICE + 1,
        5000,
    );
    val requester = testing.treasury("requester");
    val referrer = randomAddress("referrer");

    val result = publicDeploy(collection, requester.address, referrer, TEST_DEPLOY_VALUE + 1);

    expect(result).toHaveTx({
        from: collection.address,
        to: referrer,
        // the reward drops half a nanogram: rounding to the nearest value gives a different result
        value: (TEST_DEPLOY_PRICE + 1) / 2,
    });
}

/// A public deploy pays the price at the time the collection processes it. If the admin raises
/// the price first, the price absorbs the value that the requester meant for the wallet.
get fun `test public deploy: price raised before the deploy should absorb the wallet leftover`() {
    val (collection, admin, _) = setupTest();
    val requester = testing.treasury("requester");
    val walletAddress = collection.getNftAddressByIndex(0);
    val value = collection.getCollectionSettings().deployPrice + grams("2");

    editSettings(
        collection,
        admin.address,
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        value - MIN_WALLET_STORAGE,
    );
    val collectionBefore = testing.getAccountBalance(collection.address);

    val result = publicDeploy(collection, requester.address, null, value);

    expect(result).toHaveSuccessfulDeploy({ from: collection.address, to: walletAddress });
    expect(testing.getAccountBalance(walletAddress)).toBeLess(
        MIN_WALLET_STORAGE + WALLET_DEPLOY_FEES,
    );
    expect(testing.getAccountBalance(collection.address) - collectionBefore).toBeGreater(
        grams("2"),
    );
}

get fun `test public deploy: should allow self-referral`() {
    val (collection, _, _) = setupTest();
    val requester = testing.treasury("requester");

    val result = publicDeploy(collection, requester.address, requester.address, TEST_DEPLOY_VALUE);

    expect(result).toHaveSuccessfulDeploy({
        from: collection.address,
        to: collection.getNftAddressByIndex(0),
    });
    expect(result).toHaveTx({
        from: collection.address,
        to: requester.address,
        value: TEST_DEPLOY_PRICE * TEST_REFERRAL_BPS / REFERRAL_BPS_DENOMINATOR,
        bounce: false,
    });
}

get fun `test public deploy: should not pay a zero referral reward`() {
    val (collection, _, _) = setupTest(
        TEST_COLLECTION_DEPLOY_VALUE,
        "royaltyAddress",
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        TEST_DEPLOY_PRICE,
        0,
    );
    val requester = testing.treasury("requester");
    val referrer = randomAddress("referrer");

    val result = publicDeploy(collection, requester.address, referrer, TEST_DEPLOY_VALUE);

    expect(result).toHaveSuccessfulDeploy({
        from: collection.address,
        to: collection.getNftAddressByIndex(0),
    });
    expect(result).toNotHaveTx({ from: collection.address, to: referrer });
}

/// Expects a rejected public deploy. The request bounces to the sender, nothing is deployed or
/// paid, and the collection does not change.
fun expectPublicDeployRejected(
    collection: AgenticCollection,
    result: SendResultList,
    sender: address,
    exitCode: int,
    before: CollectionSnapshot,
) {
    expect(result).toHaveFailedTx<RelayPublicDeployWallet>({
        from: sender,
        to: collection.address,
        exitCode,
    });
    expect(result).toHaveTx({ from: collection.address, to: sender, bounced: true });
    expect(result).toNotHaveTx({ from: collection.address, deploy: true });
    expect(result).toNotHaveTx({ from: collection.address, bounced: false });
    expect(snapshot(collection)).toEqual(before);
    expect(
        testing.isDeployed(collection.getNftAddressByIndex(before.data.nextWalletIndex)),
    ).toBeFalse();
}

/// Checks a public deploy with a failed action phase. The request bounced, the collection sent
/// nothing else and kept its balance.
fun expectPublicDeployActionFailed(
    collection: AgenticCollection,
    result: SendResultList,
    sender: address,
    before: CollectionSnapshot,
    balanceBefore: coins,
) {
    expect(result).toHaveTx<RelayPublicDeployWallet>({
        from: sender,
        to: collection.address,
        exitCode: 0,
        success: false,
        actionExitCode: fun(code) {
            return code != 0;
        },
    });
    expect(result).toHaveTx({ from: collection.address, to: sender, bounced: true });
    expect(result).toNotHaveTx({ from: collection.address, deploy: true });
    expect(result).toNotHaveTx({ from: collection.address, bounced: false });
    expect(snapshot(collection)).toEqual(before);
    expect(testing.getAccountBalance(collection.address)).toBeGreaterOrEqual(balanceBefore);
    expect(
        testing.isDeployed(collection.getNftAddressByIndex(before.data.nextWalletIndex)),
    ).toBeFalse();
}

get fun `test public deploy: should reject a masterchain referral`() {
    val (collection, _, _) = setupTest();
    val requester = testing.treasury("requester");
    val before = snapshot(collection);

    val referral = publicDeploy(
        collection,
        requester.address,
        randomAddress("referrer", MASTERCHAIN),
        TEST_DEPLOY_VALUE,
    );
    expectPublicDeployRejected(
        collection,
        referral,
        requester.address,
        Errors.InvalidWorkchain,
        before,
    );
}

get fun `test public deploy: should reject a masterchain sender`() {
    val (collection, _, _) = setupTest();
    val requester = testing.treasury("masterchain-requester", MASTERCHAIN);
    val before = snapshot(collection);

    val result = publicDeploy(
        collection,
        requester.address,
        randomAddress("referrer"),
        TEST_DEPLOY_VALUE,
    );
    expectPublicDeployRejected(
        collection,
        result,
        requester.address,
        Errors.InvalidWorkchain,
        before,
    );
}

get fun `test public deploy: disabled public deploys should still allow admin deploys`() {
    val (collection, admin, _) = setupTest(
        TEST_COLLECTION_DEPLOY_VALUE,
        "royaltyAddress",
        MAX_WALLET_INDEX_UNLIMITED,
        false,
    );
    val requester = testing.treasury("requester");
    val before = snapshot(collection);

    val rejected = publicDeploy(collection, requester.address, null, TEST_DEPLOY_VALUE);
    expectPublicDeployRejected(
        collection,
        rejected,
        requester.address,
        Errors.PublicDeployDisabled,
        before,
    );
    // the setting also applies to the admin who sends the public message
    val adminRejected = publicDeploy(collection, admin.address, null, TEST_DEPLOY_VALUE);
    expectPublicDeployRejected(
        collection,
        adminRejected,
        admin.address,
        Errors.PublicDeployDisabled,
        before,
    );

    nftFixture(collection, testing.treasury("owner").address);
    expect(collection.getCollectionData().nextWalletIndex).toEqual(1);

    editSettings(collection, admin.address, MAX_WALLET_INDEX_UNLIMITED);
    val enabled = publicDeploy(collection, requester.address, null, TEST_DEPLOY_VALUE);
    expect(enabled).toHaveSuccessfulDeploy({
        from: collection.address,
        to: collection.getNftAddressByIndex(1),
    });

    editSettings(collection, admin.address, MAX_WALLET_INDEX_UNLIMITED, false);
    val beforeDisabled = snapshot(collection);
    val disabledAgain = publicDeploy(collection, requester.address, null, TEST_DEPLOY_VALUE);
    expectPublicDeployRejected(
        collection,
        disabledAgain,
        requester.address,
        Errors.PublicDeployDisabled,
        beforeDisabled,
    );
}

get fun `test public deploy: should require the price plus the storage reserve`() {
    val (collection, _, _) = setupTest();
    val requester = testing.treasury("requester");
    val before = snapshot(collection);
    val smallest = TEST_DEPLOY_PRICE + MIN_WALLET_STORAGE;

    val short = publicDeploy(collection, requester.address, null, smallest - 1);
    expectPublicDeployRejected(
        collection,
        short,
        requester.address,
        Errors.TooSmallDeployValue,
        before,
    );

    val exact = publicDeploy(collection, requester.address, null, smallest);
    val walletAddress = collection.getNftAddressByIndex(0);
    expect(exact).toHaveSuccessfulDeploy({ from: collection.address, to: walletAddress });
    expect(exact).toHaveTx<NotificationForNewOwner>({ from: walletAddress, to: requester.address });
    expect(testing.getAccountBalance(walletAddress)).toBeGreaterOrEqual(MIN_WALLET_STORAGE);
}

/// The collection pays the deploy from the price minus the reward. If the price can not pay it,
/// the action phase fails, and the collection balance stays.
get fun `test public deploy: should fail when the price cannot cover the deploy`() {
    val (collection, admin, _) = setupTest(
        TEST_COLLECTION_DEPLOY_VALUE,
        "royaltyAddress",
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        WALLET_DEPLOY_FEES,
        0,
    );
    val requester = testing.treasury("requester");
    val referrer = randomAddress("referrer");
    val before = snapshot(collection);
    val balanceBefore = testing.getAccountBalance(collection.address);

    // the price pays the wallet gas, but not the collection fees
    val cheap = publicDeploy(collection, requester.address, null, grams("1"));
    expectPublicDeployActionFailed(collection, cheap, requester.address, before, balanceBefore);

    // enough without a referral, but not after a 90% referral reward
    editSettings(
        collection,
        admin.address,
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        grams("0.008"),
        9000,
    );
    val beforeReferral = snapshot(collection);
    val balanceBeforeReferral = testing.getAccountBalance(collection.address);
    val referral = publicDeploy(collection, requester.address, referrer, grams("1"));
    expectPublicDeployActionFailed(
        collection,
        referral,
        requester.address,
        beforeReferral,
        balanceBeforeReferral,
    );

    val noReferral = publicDeploy(collection, requester.address, null, grams("1"));
    expect(noReferral).toHaveSuccessfulDeploy({
        from: collection.address,
        to: collection.getNftAddressByIndex(0),
    });
    expect(testing.getAccountBalance(collection.address)).toBeGreaterOrEqual(
        balanceBeforeReferral,
    );
}

/// The collection never accepts gas. If the value is too small for the gas, the compute phase
/// fails, and the sender pays.
get fun `test public deploy: value below the gas should not spend the collection balance`() {
    val (collection, _, _) = setupTest();
    val requester = testing.treasury("requester");
    val before = snapshot(collection);
    val balanceBefore = testing.getAccountBalance(collection.address);

    val result = publicDeploy(collection, requester.address, randomAddress("referrer"), 1);

    // out of gas
    expect(result).toHaveFailedTx<RelayPublicDeployWallet>({
        from: requester.address,
        to: collection.address,
        exitCode: -14,
    });
    expect(result).toNotHaveTx({ from: collection.address, deploy: true });
    expect(result).toNotHaveTx({ from: collection.address, bounced: false });
    expect(snapshot(collection)).toEqual(before);
    expect(testing.getAccountBalance(collection.address)).toBeGreaterOrEqual(balanceBefore);
}

/// A forward fee increase above the buffers makes the deploy send fail, and +16 bounces the
/// request. The test sets the fee in the config, because a validator vote is not practical.
get fun `test public deploy: action phase failure should bounce to the sender`() {
    val (collection, _, _) = setupTest(
        TEST_COLLECTION_DEPLOY_VALUE,
        "royaltyAddress",
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        grams("0.01"),
        0,
    );
    val requester = testing.treasury("requester");
    var config = testing.getConfig();
    var prices = config.getMsgForwardPrices(BASECHAIN);
    prices.bitPrice *= 100;
    prices.cellPrice *= 100;
    config.setMsgForwardPrices(prices, BASECHAIN);
    testing.setConfig(config);
    val before = snapshot(collection);
    val balanceBefore = testing.getAccountBalance(collection.address);

    val result = publicDeploy(collection, requester.address, null, TEST_DEPLOY_VALUE);

    expectPublicDeployActionFailed(collection, result, requester.address, before, balanceBefore);
    // the value goes back, minus the fees
    expect(testing.getAccountBalance(collection.address)).toBeLess(balanceBefore + grams("0.01"));
}

/// Forward fee of the collection deploy message for a public deploy of wallet 0.
fun publicDeployForwardFee(collection: AgenticCollection, owner: address): coins {
    val deployMsg = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: {
            workchain: BASECHAIN,
            stateInit: {
                code: build("AgenticWallet"),
                data: AgenticWalletStorageNotInitialized {
                    seqno: 0,
                    walletIndex: 0,
                    collectionAddress: collection.address,
                }.toCell(),
            },
        },
        value: grams("1"),
        body: DeployWallet {
            queryId: 0,
            initParams: walletInitParams(
                owner,
                TraitSetContent { traitSetIndex: 0 }.toCell(),
                0,
                MIN_FORWARD_AMOUNT,
            ).toCell(),
        },
    });
    return deployMsg.estimateFeeWithoutSending(SEND_MODE_REGULAR);
}

/// `WALLET_DEPLOY_FEES` pays the larger of two amounts, with a small margin. The first is what the
/// wallet deploy check needs in addition to the storage reserve (forward amount and fee). The
/// second is what the deploy spends. The size of a public deploy message never changes.
get fun `test public deploy: WALLET_DEPLOY_FEES should cover the wallet's needs`() {
    val (collection, _, _) = setupTest();
    val requester = testing.treasury("requester");
    val value = TEST_DEPLOY_PRICE + grams("1");
    val checkNeed = MIN_FORWARD_AMOUNT + publicDeployForwardFee(collection, requester.address);

    publicDeploy(collection, requester.address, null, value);

    val deployValue = value - TEST_DEPLOY_PRICE + WALLET_DEPLOY_FEES;
    val spent = deployValue - testing.getAccountBalance(collection.getNftAddressByIndex(0));
    val need = max(checkNeed, spent);
    expect(WALLET_DEPLOY_FEES).toBeGreaterOrEqual(need);
    expect(WALLET_DEPLOY_FEES - need).toBeLessOrEqual(grams("0.0002"));
}

/// The script defaults pay the wallet storage reserve and notify the owner, so a marketplace
/// listing works immediately.
get fun `test script defaults: a wallet deploy should fund the storage reserve and notify the owner`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val requester = testing.treasury("requester");

    val adminDeploy = collection.sendRelayDeployWallet(
        admin.address,
        0,
        null,
        DEFAULT_WALLET_ATTACH_AMOUNT,
        AgenticWalletInitParams.create(
            owner.address,
            createEmptyCell(),
            0,
            MIN_FORWARD_AMOUNT,
            emptyForwardPayload(),
        ),
        { value: DEFAULT_DEPLOY_MESSAGE_VALUE, bounce: true },
    );
    val adminWallet = collection.getNftAddressByIndex(0);
    expect(adminDeploy).toHaveTx<NotificationForNewOwner>({ from: adminWallet, to: owner.address });
    expect(testing.getAccountBalance(adminWallet)).toBeGreaterOrEqual(MIN_WALLET_STORAGE);

    val listing = AgenticWallet
        .fromAddress(adminWallet)
        .sendChangeWalletOwnerPayloadInline(
            owner.address,
            0,
            randomAddress("getgems-sale-deployer"),
            owner.address,
            null,
            grams("0.2"),
            createEmptySlice(),
            { value: grams("0.219"), bounce: true },
        );
    expect(
        listing,
    ).toHaveSuccessfulTx<ChangeWalletOwner>({ from: owner.address, to: adminWallet });

    val publicDeployResult = publicDeploy(
        collection,
        requester.address,
        null,
        TEST_DEPLOY_PRICE + DEFAULT_WALLET_LEFTOVER,
    );
    val publicWallet = collection.getNftAddressByIndex(1);
    expect(publicDeployResult).toHaveTx<NotificationForNewOwner>({
        from: publicWallet,
        to: requester.address,
    });
    expect(testing.getAccountBalance(publicWallet)).toBeGreaterOrEqual(MIN_WALLET_STORAGE);
}

/// Init params that the deploy script builds for a URL and forward comment of `SCRIPT_SIZED_TEXT`.
fun scriptSizedInitParams(ownerAddress: address): AgenticWalletInitParams {
    return AgenticWalletInitParams.createPayloadAuto(
        ownerAddress,
        walletContent(SCRIPT_SIZED_TEXT),
        1,
        MIN_FORWARD_AMOUNT,
        commentBody(SCRIPT_SIZED_TEXT)!.beginParse(),
    );
}

/// The collection deploy value of the script leaves the storage reserve in the collection.
get fun `test script defaults: DEFAULT_DEPLOY_VALUE should keep the collection storage reserve`() {
    val (collection, _, _) = setupTest(DEFAULT_DEPLOY_VALUE);

    expect(testing.getAccountBalance(collection.address)).toBeGreaterOrEqual(
        MIN_COLLECTION_STORAGE,
    );
}

/// The script attach amount pays the wallet storage reserve and the owner notification for the
/// script-sized inputs. The message value is large, so the test checks only the attach amount.
get fun `test script defaults: DEFAULT_WALLET_ATTACH_AMOUNT should fund the wallet reserve and notify the owner`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val attachAmount = DEFAULT_WALLET_ATTACH_AMOUNT + MIN_FORWARD_AMOUNT;

    val result = collection.sendRelayDeployWallet(
        admin.address,
        0,
        null,
        attachAmount,
        scriptSizedInitParams(owner.address),
        { value: attachAmount + SETUP_DEPLOY_VALUE, bounce: true },
    );

    val wallet = collection.getNftAddressByIndex(0);
    expect(result).toHaveTx<NotificationForNewOwner>({ from: wallet, to: owner.address });
    expect(testing.getAccountBalance(wallet)).toBeGreaterOrEqual(MIN_WALLET_STORAGE);
}

/// A forward comment that fits in its own cell can be too long for the init params cell. The
/// script then puts it in a ref, and the owner still gets the notification.
get fun `test script defaults: forward comment too long for the init params should deploy`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val comment = "0123456789012345678901234567890123456789012345678901234567890123456789";
    val body = commentBody(comment)!;
    expect(body.beginParse().remainingRefsCount()).toEqual(0);

    val params = AgenticWalletInitParams.createPayloadAuto(
        owner.address,
        createEmptyCell(),
        0,
        MIN_FORWARD_AMOUNT,
        body.beginParse(),
    );
    val result = collection.sendRelayDeployWallet(
        admin.address,
        0,
        null,
        DEFAULT_WALLET_ATTACH_AMOUNT + MIN_FORWARD_AMOUNT,
        params,
        { value: DEFAULT_DEPLOY_MESSAGE_VALUE + MIN_FORWARD_AMOUNT, bounce: true },
    );

    val wallet = collection.getNftAddressByIndex(0);
    expect(result).toHaveTx({
        from: wallet,
        to: owner.address,
        body: NotificationForNewOwner {
            queryId: 0,
            oldOwnerAddress: collection.address,
            forwardPayload: params.forwardPayload,
        }.toCell(),
    });
    var payload = params.forwardPayload;
    expect(payload.loadBool()).toBeTrue();
    expect(payload.preloadRef().hash()).toEqual(body.hash());
}

/// The script deploy message value pays the collection gas and forward fee in addition to the
/// attach amount for script-sized inputs. The collection balance does not decrease.
get fun `test script defaults: DEFAULT_DEPLOY_MESSAGE_VALUE should pay the collection's gas and forward fee`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val balanceBefore = testing.getAccountBalance(collection.address);

    val result = collection.sendRelayDeployWallet(
        admin.address,
        0,
        null,
        DEFAULT_WALLET_ATTACH_AMOUNT + MIN_FORWARD_AMOUNT,
        scriptSizedInitParams(owner.address),
        { value: DEFAULT_DEPLOY_MESSAGE_VALUE + MIN_FORWARD_AMOUNT, bounce: true },
    );

    // checks only the collection: the wallet deploy depends on the attach amount
    expect(result).toHaveSuccessfulTx<RelayDeployWallet>({
        from: admin.address,
        to: collection.address,
    });
    expect(result).toHaveTx({ from: collection.address, to: collection.getNftAddressByIndex(0) });
    expect(testing.getAccountBalance(collection.address)).toBeGreaterOrEqual(balanceBefore);
}

/// The script message value pays the relay of a script-sized content URL to a wallet.
get fun `test script defaults: DEFAULT_MESSAGE_VALUE should cover a wallet content relay`() {
    val (collection, admin, _) = setupTest();
    val wallet = nftFixture(collection, testing.treasury("owner").address);

    val result = collection.sendRelayEditWalletContent(
        admin.address,
        0,
        0,
        walletContent(SCRIPT_SIZED_TEXT),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveSuccessfulTx<EditWalletContent>({
        from: collection.address,
        to: wallet.address,
    });
}

/// The lowest net price that the scripts accept still pays a public deploy and its referral reward.
get fun `test script defaults: MIN_NET_DEPLOY_PRICE should cover a public deploy after the referral share`() {
    val (collection, admin, _) = setupTest();
    val requester = testing.treasury("requester");
    val referrer = randomAddress("referrer");
    // the referrer gets half the price, and the lowest net price stays
    val price = MIN_NET_DEPLOY_PRICE * 2;
    editSettings(
        collection,
        admin.address,
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        price,
        5000,
    );

    val result = publicDeploy(
        collection,
        requester.address,
        referrer,
        price + DEFAULT_WALLET_LEFTOVER,
    );

    expect(result).toHaveSuccessfulDeploy({
        from: collection.address,
        to: collection.getNftAddressByIndex(0),
    });
    expect(result).toHaveTx({ from: collection.address, to: referrer });
}

/// A fee increase that lets the deploy send succeed, but makes the referral send fail. The +16
/// of the referral send bounces the request and drops the queued deploy.
get fun `test public deploy: referral send failure should bounce to the sender`() {
    val price = grams("1");
    val (collection, _, _) = setupTest(
        grams("0.001"),
        "royaltyAddress",
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        price,
        5000,
    );
    val requester = testing.treasury("requester");
    val referrer = randomAddress("referrer");
    val reward = price / 2;

    // aims between two limits: the deploy fits below the price minus the wallet deploy fees, and
    // the referral fails above that limit minus the reward
    val target = price - WALLET_DEPLOY_FEES - reward / 2;
    var config = testing.getConfig();
    var prices = config.getMsgForwardPrices(BASECHAIN);
    val variable = publicDeployForwardFee(collection, requester.address) - prices.lumpPrice;
    val factor = (target - prices.lumpPrice) / variable;
    prices.bitPrice *= factor;
    prices.cellPrice *= factor;
    config.setMsgForwardPrices(prices, BASECHAIN);
    testing.setConfig(config);
    val deployFee = publicDeployForwardFee(collection, requester.address);
    expect(deployFee).toBeGreater(target - reward / 4);
    expect(deployFee).toBeLess(target + reward / 4);
    val before = snapshot(collection);
    val balanceBefore = testing.getAccountBalance(collection.address);

    val result = publicDeploy(
        collection,
        requester.address,
        referrer,
        price + DEFAULT_WALLET_LEFTOVER,
    );

    // the queued deploy is also dropped
    expectPublicDeployActionFailed(collection, result, requester.address, before, balanceBefore);
}

/// Deploys a wallet for a treasury named after `index`. Returns the trait set index that it drew.
fun publicDeployTraitSetIndex(collection: AgenticCollection, index: int): int {
    val walletIndex = collection.getCollectionData().nextWalletIndex;
    val requester = testing.treasury(format("requester-{}", index));
    val result = publicDeploy(collection, requester.address, null, grams("5"));

    expect(result).toHaveSuccessfulTx<RelayPublicDeployWallet>({
        from: requester.address,
        to: collection.address,
    });

    val wallet = AgenticWallet.fromAddress(collection.getNftAddressByIndex(walletIndex));

    return TraitSetContent.fromCell(wallet.getNftData().content!).traitSetIndex;
}

get fun `test public deploy: should draw every trait set below the count and no other`() {
    testing.setRandomSeed(1);
    val (collection, _, _) = setupTest(
        TEST_COLLECTION_DEPLOY_VALUE,
        "royaltyAddress",
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        TEST_DEPLOY_PRICE,
        TEST_REFERRAL_BPS,
        3,
    );
    var seen = 0;

    var i = 0;
    while (i < 30) {
        val traitSetIndex = publicDeployTraitSetIndex(collection, i);
        expect(traitSetIndex).toBeLess(3);
        seen |= 1 << traitSetIndex;
        i += 1;
    }

    expect(seen).toEqual(0b111);
}

/// With a fixed seed, each deploy starts from the same VM seed, as in one block. Only the logical
/// time makes the draws different.
get fun `test public deploy: should draw independently from one seed`() {
    testing.setRandomSeed(2);
    val (collection, _, _) = setupTest();
    val first = publicDeployTraitSetIndex(collection, 0);
    var anyDifferent = false;

    var i = 1;
    while (i < 10) {
        testing.setRandomSeed(2);
        anyDifferent = anyDifferent || publicDeployTraitSetIndex(collection, i) != first;
        i += 1;
    }

    expect(anyDifferent).toBeTrue();
}

get fun `test public deploy: a count of 1 or 0 should always draw trait set 0`() {
    val (collection, admin, _) = setupTest();
    editSettings(
        collection,
        admin.address,
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        TEST_DEPLOY_PRICE,
        TEST_REFERRAL_BPS,
        1,
    );
    expect(publicDeployTraitSetIndex(collection, 0)).toEqual(0);
    expect(publicDeployTraitSetIndex(collection, 1)).toEqual(0);

    editSettings(
        collection,
        admin.address,
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        TEST_DEPLOY_PRICE,
        TEST_REFERRAL_BPS,
        0,
    );
    expect(publicDeployTraitSetIndex(collection, 2)).toEqual(0);
    expect(publicDeployTraitSetIndex(collection, 3)).toEqual(0);
}

get fun `test public deploy: later deploys should draw from an edited count`() {
    testing.setRandomSeed(3);
    val (collection, admin, _) = setupTest(
        TEST_COLLECTION_DEPLOY_VALUE,
        "royaltyAddress",
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        TEST_DEPLOY_PRICE,
        TEST_REFERRAL_BPS,
        1,
    );
    expect(publicDeployTraitSetIndex(collection, 0)).toEqual(0);

    editSettings(
        collection,
        admin.address,
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        TEST_DEPLOY_PRICE,
        TEST_REFERRAL_BPS,
        0xFFFF,
    );
    var anyAboveZero = false;

    var i = 1;
    while (i < 5) {
        anyAboveZero = anyAboveZero || publicDeployTraitSetIndex(collection, i) > 0;
        i += 1;
    }

    expect(anyAboveZero).toBeTrue();
}

get fun `test public deploy: get_nft_content should expand the drawn trait set`() {
    val (collection, admin, _) = setupTest();
    collection.sendEditCollectionContent(
        admin.address,
        0,
        newCollectionContent(),
        newRoyaltyParams(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    val traitSetIndex = publicDeployTraitSetIndex(collection, 0);
    val wallet = AgenticWallet.fromAddress(collection.getNftAddressByIndex(0));
    val url = offchainUrl(collection.getNftContent(0, wallet.getNftData().content!));

    expect(url.equalTo(format("https://example.com/agents/{}/0.json", traitSetIndex))).toBeTrue();
}

get fun `test collection: should reject a wallet deploy from a non-admin`() {
    val (collection, _, _) = setupTest();
    val notAdmin = testing.treasury("not-admin");
    val before = snapshot(collection);

    val result = deployWallet(
        collection,
        notAdmin.address,
        null,
        walletInitParams(notAdmin.address, createEmptyCell()),
    );

    expect(result).toHaveFailedTx<RelayDeployWallet>({
        from: notAdmin.address,
        to: collection.address,
        exitCode: Errors.NotFromAdmin,
    });
    expect(result).toNotHaveTx({ from: collection.address, deploy: true });
    expect(snapshot(collection)).toEqual(before);
}

/// An explicit index only retries an allocated index, so it can not compete with a public
/// deploy for the next index.
get fun `test collection: should reject an explicit index equal to the next index`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val requester = testing.treasury("requester");
    publicDeploy(collection, requester.address, null, TEST_DEPLOY_VALUE);
    val before = snapshot(collection);

    val result = deployWallet(
        collection,
        admin.address,
        1,
        walletInitParams(owner.address, createEmptyCell()),
    );

    expect(result).toHaveFailedTx<RelayDeployWallet>({
        from: admin.address,
        to: collection.address,
        exitCode: Errors.InvalidWalletIndex,
    });
    expect(result).toNotHaveTx({ from: collection.address, deploy: true });
    expect(snapshot(collection)).toEqual(before);
}

get fun `test collection: should reject a wallet deploy on another network`() {
    val deployer = testing.treasury("deployer");
    val collection = AgenticCollection.fromStorage(
        AgenticCollectionStorage.create(
            deployer.address,
            blockchain.globalId() + 1,
            build("AgenticWallet"),
            emptyCollectionContent(),
            newRoyaltyParams(),
            {
                maxWalletIndex: MAX_WALLET_INDEX_UNLIMITED,
                publicDeployEnabled: true,
                deployPrice: TEST_DEPLOY_PRICE,
                referralBps: TEST_REFERRAL_BPS,
                traitSetCount: TEST_TRAIT_SET_COUNT,
            },
        ),
    );
    collection.deploy(deployer.address, { value: TEST_COLLECTION_DEPLOY_VALUE, bounce: false });

    val result = deployWallet(
        collection,
        deployer.address,
        null,
        walletInitParams(deployer.address, createEmptyCell()),
    );

    expect(result).toHaveFailedTx<RelayDeployWallet>({
        from: deployer.address,
        to: collection.address,
        exitCode: Errors.WrongNetwork,
    });
    expect(result).toNotHaveTx({ from: collection.address, deploy: true });
    expect(collection.getCollectionData().nextWalletIndex).toEqual(0);

    val publicResult = publicDeploy(collection, deployer.address, null, TEST_DEPLOY_VALUE);
    expect(publicResult).toHaveFailedTx<RelayPublicDeployWallet>({
        from: deployer.address,
        to: collection.address,
        exitCode: Errors.WrongNetwork,
    });
    expect(publicResult).toNotHaveTx({ from: collection.address, deploy: true });
    expect(collection.getCollectionData().nextWalletIndex).toEqual(0);
}

get fun `test collection: admin should edit wallet content`() {
    val (collection, admin, _) = setupTest();
    val wallet = nftFixture(collection, testing.treasury("owner").address);
    val newContent = beginCell().storeString("new content").endCell();

    val result = collection.sendRelayEditWalletContent(
        admin.address,
        0,
        0,
        newContent,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveSuccessfulTx<RelayEditWalletContent>({
        from: admin.address,
        to: collection.address,
    });
    expect(result).toHaveSuccessfulTx<EditWalletContent>({
        from: collection.address,
        to: wallet.address,
    });
    expect(wallet.getNftData().content!).toEqual(newContent);
}

get fun `test collection: should reject a wallet content edit from a non-admin`() {
    val (collection, _, _) = setupTest();
    val notAdmin = testing.treasury("not-admin");
    val wallet = nftFixture(collection, testing.treasury("owner").address);
    val before = wallet.getNftData();

    val result = collection.sendRelayEditWalletContent(
        notAdmin.address,
        0,
        0,
        beginCell().storeString("forbidden").endCell(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveFailedTx<RelayEditWalletContent>({
        from: notAdmin.address,
        to: collection.address,
        exitCode: Errors.NotFromAdmin,
    });
    expect(result).toNotHaveTx<EditWalletContent>({ to: wallet.address });
    expect(wallet.getNftData()).toEqual(before);
}

get fun `test collection: should reject a content edit for a wallet not deployed yet`() {
    val (collection, admin, _) = setupTest();
    nftFixture(collection, testing.treasury("owner").address);
    val nextWalletIndex = collection.getCollectionData().nextWalletIndex;

    val result = collection.sendRelayEditWalletContent(
        admin.address,
        0,
        nextWalletIndex,
        beginCell().storeString("not minted").endCell(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveFailedTx<RelayEditWalletContent>({
        from: admin.address,
        to: collection.address,
        exitCode: Errors.InvalidWalletIndex,
    });
    expect(result).toNotHaveTx<EditWalletContent>({ from: collection.address });
}

get fun `test collection: content relay action failure should bounce to the admin`() {
    val (collection, admin, _) = setupTest();
    val wallet = nftFixture(collection, testing.treasury("owner").address);
    val contentBefore = wallet.getNftData().content!;
    // only the relayed message has refs: it can not pay its forward fee, but the bounce can
    var config = testing.getConfig();
    var prices = config.getMsgForwardPrices(BASECHAIN);
    prices.cellPrice *= 100000;
    config.setMsgForwardPrices(prices, BASECHAIN);
    testing.setConfig(config);

    val result = collection.sendRelayEditWalletContent(
        admin.address,
        0,
        0,
        beginCell().storeString("new content").endCell(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveTx<RelayEditWalletContent>({
        from: admin.address,
        to: collection.address,
        exitCode: 0,
        success: false,
        actionExitCode: fun(code) {
            return code != 0;
        },
    });
    expect(result).toHaveTx({ from: collection.address, to: admin.address, bounced: true });
    expect(result).toNotHaveTx<EditWalletContent>({ from: collection.address });
    expect(wallet.getNftData().content!).toEqual(contentBefore);
}

get fun `test collection: previous admin should lose admin rights`() {
    val (collection, oldAdmin, _) = setupTest();
    val newAdmin = testing.treasury("new-admin");

    collection.sendChangeCollectionAdmin(
        oldAdmin.address,
        0,
        newAdmin.address,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );
    val before = snapshot(collection);

    val result = collection.sendChangeCollectionAdmin(
        oldAdmin.address,
        0,
        oldAdmin.address,
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveFailedTx<ChangeCollectionAdmin>({
        from: oldAdmin.address,
        to: collection.address,
        exitCode: Errors.NotFromAdmin,
    });
    expect(snapshot(collection)).toEqual(before);
    expect(before.data.adminAddress).toEqual(newAdmin.address);
}

/// The wallet address does not depend on the init params, so the retry can have all new ones.
get fun `test collection: should accept a bounced wallet deploy and allow a retry with new init params`() {
    val (collection, admin, _) = setupTest();
    val firstOwner = testing.treasury("first-owner");
    val retryOwner = testing.treasury("retry-owner");
    val wallet = AgenticWallet.fromAddress(collection.getNftAddressByIndex(0));

    val result = deployWallet(
        collection,
        admin.address,
        null,
        invalidInitParams(firstOwner.address),
    );

    expect(result).toHaveFailedTx<DeployWallet>({
        from: collection.address,
        to: wallet.address,
        exitCode: Errors.IncorrectForwardPayload,
    });
    expect(result).toHaveTx({
        from: wallet.address,
        to: collection.address,
        bounced: true,
        success: true,
    });
    // the StateInit activates the account, but the wallet stays uninitialized
    expect(wallet.getNftData().isInitialized).toBeFalse();

    // the admin can still deploy the index, with any init params
    val retryContent = beginCell().storeString("retry").endCell();
    val retry = deployWallet(
        collection,
        admin.address,
        0,
        {
            ownerAddress: retryOwner.address,
            content: retryContent,
            delegatePublicKey: 0xABCD,
            forwardAmount: 0,
            forwardPayload: emptyForwardPayload().toCell().beginParse(),
        },
    );

    expect(retry).toHaveSuccessfulTx<DeployWallet>({
        from: collection.address,
        to: wallet.address,
    });
    val data = wallet.getNftData();
    expect(data.isInitialized).toBeTrue();
    expect(data.ownerAddress).toEqual(retryOwner.address);
    expect(data.content).toEqual(retryContent);
    expect(wallet.getPublicKey()).toEqual(0xABCD);
    expect(collection.getCollectionData().nextWalletIndex).toEqual(1);
}

get fun `test collection: get_collection_settings should return the deployed settings`() {
    val (unlimited, _, _) = setupTest();
    expect(unlimited.getCollectionSettings()).toEqual(CollectionSettingsReply {
        maxWalletIndex: MAX_WALLET_INDEX_UNLIMITED,
        publicDeployEnabled: true,
        deployPrice: TEST_DEPLOY_PRICE,
        referralBps: TEST_REFERRAL_BPS,
        traitSetCount: TEST_TRAIT_SET_COUNT,
    });

    val (limited, _, _) = setupTest(
        TEST_COLLECTION_DEPLOY_VALUE,
        "royaltyAddress",
        7,
        false,
        grams("2"),
        250,
        7,
    );
    expect(limited.getCollectionSettings()).toEqual(CollectionSettingsReply {
        maxWalletIndex: 7,
        publicDeployEnabled: false,
        deployPrice: grams("2"),
        referralBps: 250,
        traitSetCount: 7,
    });
}

get fun `test collection: admin should edit collection settings`() {
    val (collection, admin, _) = setupTest();
    val values: array<CollectionSettingsReply> = [
        {
            maxWalletIndex: 5,
            publicDeployEnabled: false,
            deployPrice: grams("1"),
            referralBps: 0,
            traitSetCount: 1,
        },
        {
            maxWalletIndex: 0,
            publicDeployEnabled: true,
            deployPrice: 0,
            referralBps: 10000,
            traitSetCount: 0xFFFF,
        },
        {
            maxWalletIndex: MAX_WALLET_INDEX_UNLIMITED,
            publicDeployEnabled: true,
            deployPrice: grams("3"),
            referralBps: 1,
            traitSetCount: 0,
        },
    ];
    val before = snapshot(collection);

    var i = 0;
    while (i < 3) {
        val value = values.get(i);
        val result = editSettings(
            collection,
            admin.address,
            value.maxWalletIndex,
            value.publicDeployEnabled,
            value.deployPrice,
            value.referralBps,
            value.traitSetCount,
        );

        expect(result).toHaveSuccessfulTx<EditCollectionSettings>({
            from: admin.address,
            to: collection.address,
        });
        expect(result).toNotHaveTx({ from: collection.address });
        expect(collection.getCollectionSettings()).toEqual(value);
        // only the settings changed
        val after = snapshot(collection);
        expect(after.data).toEqual(before.data);
        expect(after.royaltyParams).toEqual(before.royaltyParams);
        i += 1;
    }
}

get fun `test collection: should reject a settings edit from a non-admin`() {
    val (collection, _, _) = setupTest();
    val notAdmin = testing.treasury("not-admin");
    val before = snapshot(collection);

    val result = editSettings(collection, notAdmin.address, 5);

    expect(result).toHaveFailedTx<EditCollectionSettings>({
        from: notAdmin.address,
        to: collection.address,
        exitCode: Errors.NotFromAdmin,
    });
    expect(snapshot(collection)).toEqual(before);
}

/// A cap below the next index stops new public and admin deploys. The collection still relays
/// admin retries.
get fun `test collection: should accept a max wallet index below the last deployed index`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val requester = testing.treasury("requester");
    nftFixture(collection, owner.address);
    nftFixture(collection, owner.address);

    val lowered = editSettings(collection, admin.address, 0);
    expect(lowered).toHaveSuccessfulTx<EditCollectionSettings>({
        from: admin.address,
        to: collection.address,
    });
    expect(collection.getCollectionSettings().maxWalletIndex).toEqual(0);

    val adminNew = deployWallet(
        collection,
        admin.address,
        null,
        walletInitParams(owner.address, createEmptyCell()),
    );
    expectWalletLimitReached(adminNew, admin.address, collection.address);
    val publicNew = publicDeploy(collection, requester.address, null, TEST_DEPLOY_VALUE);
    expectWalletLimitReached(publicNew, requester.address, collection.address);

    // the collection relays the retry, but the initialized wallet rejects it
    val retry = deployWallet(
        collection,
        admin.address,
        0,
        walletInitParams(owner.address, createEmptyCell()),
    );
    expect(retry).toHaveSuccessfulTx<RelayDeployWallet>({
        from: admin.address,
        to: collection.address,
    });
    expect(retry).toHaveFailedTx<DeployWallet>({
        from: collection.address,
        to: collection.getNftAddressByIndex(0),
        exitCode: Errors.AlreadyInitialized,
    });
    expect(collection.getCollectionData().nextWalletIndex).toEqual(2);
}

/// On a new collection, the smallest cap (0) still permits a deploy at index 0.
get fun `test collection: fresh collection should accept the smallest max wallet index`() {
    val (collection, admin, _) = setupTest();

    val result = editSettings(collection, admin.address, 0);
    expect(result).toHaveSuccessfulTx<EditCollectionSettings>({
        from: admin.address,
        to: collection.address,
    });
    expect(collection.getCollectionSettings().maxWalletIndex).toEqual(0);

    nftFixture(collection, testing.treasury("owner").address);
    expect(collection.getCollectionData().nextWalletIndex).toEqual(1);
}

/// A share above 100% makes the reward more than the price, so the collection rejects only
/// referral deploys.
get fun `test collection: referral share above the denominator should only block referral deploys`() {
    val (collection, admin, _) = setupTest();
    val requester = testing.treasury("requester");

    val stored = editSettings(
        collection,
        admin.address,
        MAX_WALLET_INDEX_UNLIMITED,
        true,
        TEST_DEPLOY_PRICE,
        REFERRAL_BPS_DENOMINATOR + 1,
    );
    expect(stored).toHaveSuccessfulTx<EditCollectionSettings>({
        from: admin.address,
        to: collection.address,
    });
    expect(collection.getCollectionSettings().referralBps).toEqual(REFERRAL_BPS_DENOMINATOR + 1);
    val before = snapshot(collection);
    val balanceBefore = testing.getAccountBalance(collection.address);

    val referral = publicDeploy(
        collection,
        requester.address,
        randomAddress("referrer"),
        TEST_DEPLOY_VALUE,
    );
    expectPublicDeployActionFailed(collection, referral, requester.address, before, balanceBefore);

    val noReferral = publicDeploy(collection, requester.address, null, TEST_DEPLOY_VALUE);
    expect(noReferral).toHaveSuccessfulDeploy({
        from: collection.address,
        to: collection.getNftAddressByIndex(0),
    });
}

get fun `test collection: should deploy up to the max wallet index`() {
    val (collection, admin, _) = setupTest(TEST_COLLECTION_DEPLOY_VALUE, "royaltyAddress", 1);
    val owner = testing.treasury("owner");
    nftFixture(collection, owner.address);
    nftFixture(collection, owner.address);
    val before = snapshot(collection);

    val pastLimit = deployWallet(
        collection,
        admin.address,
        null,
        walletInitParams(owner.address, createEmptyCell()),
    );
    expectWalletLimitReached(pastLimit, admin.address, collection.address);
    expect(snapshot(collection)).toEqual(before);

    editSettings(collection, admin.address, 2);
    val raised = nftFixture(collection, owner.address);
    expect(raised.address).toEqual(collection.getNftAddressByIndex(2));
    expect(collection.getCollectionData().nextWalletIndex).toEqual(3);
}

get fun `test collection: public deploy should reach the max wallet index`() {
    val (collection, _, _) = setupTest(TEST_COLLECTION_DEPLOY_VALUE, "royaltyAddress", 1);
    val owner = testing.treasury("owner");
    val requester = testing.treasury("requester");
    nftFixture(collection, owner.address);

    val last = publicDeploy(collection, requester.address, null, TEST_DEPLOY_VALUE);
    expect(last).toHaveSuccessfulTx<DeployWallet>({
        from: collection.address,
        to: collection.getNftAddressByIndex(1),
    });
    expect(collection.getCollectionData().nextWalletIndex).toEqual(2);

    val pastLimit = publicDeploy(collection, requester.address, null, TEST_DEPLOY_VALUE);
    expectWalletLimitReached(pastLimit, requester.address, collection.address);
}

get fun `test collection: reached max wallet index should reject public and admin deploys`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val requester = testing.treasury("requester");
    nftFixture(collection, owner.address);
    editSettings(collection, admin.address, 0);
    val before = snapshot(collection);

    val adminDeploy = deployWallet(
        collection,
        admin.address,
        null,
        walletInitParams(owner.address, createEmptyCell()),
    );
    expectWalletLimitReached(adminDeploy, admin.address, collection.address);

    val publicResult = publicDeploy(collection, requester.address, null, TEST_DEPLOY_VALUE);
    expectWalletLimitReached(publicResult, requester.address, collection.address);

    expect(snapshot(collection)).toEqual(before);
}

/// A closed cap and disabled public deploys do not stop an admin retry, with any owner.
get fun `test collection: should retry an allocated index past the limit`() {
    val (collection, admin, _) = setupTest();
    val firstOwner = testing.treasury("first-owner");
    val retryOwner = testing.treasury("retry-owner");
    val wallet = AgenticWallet.fromAddress(collection.getNftAddressByIndex(0));
    val failed = deployWallet(
        collection,
        admin.address,
        null,
        invalidInitParams(firstOwner.address),
    );
    expect(failed).toHaveFailedTx<DeployWallet>({
        from: collection.address,
        to: wallet.address,
        exitCode: Errors.IncorrectForwardPayload,
    });
    expect(collection.getCollectionData().nextWalletIndex).toEqual(1);

    // the cap stops at the last allocated index, and public deploys are off
    editSettings(collection, admin.address, 0, false);
    val closedNew = deployWallet(
        collection,
        admin.address,
        null,
        walletInitParams(firstOwner.address, createEmptyCell()),
    );
    expectWalletLimitReached(closedNew, admin.address, collection.address);
    val closedRetry = deployWallet(
        collection,
        admin.address,
        0,
        invalidInitParams(firstOwner.address),
    );
    expect(closedRetry).toHaveFailedTx<DeployWallet>({
        from: collection.address,
        to: wallet.address,
        exitCode: Errors.IncorrectForwardPayload,
    });

    val validRetry = deployWallet(
        collection,
        admin.address,
        0,
        walletInitParams(retryOwner.address, createEmptyCell()),
    );
    expect(validRetry).toHaveSuccessfulTx<DeployWallet>({
        from: collection.address,
        to: wallet.address,
    });
    expect(wallet.getNftData().ownerAddress).toEqual(retryOwner.address);

    // an initialized wallet keeps its owner: the collection relays, and the wallet rejects
    val overwrite = deployWallet(
        collection,
        admin.address,
        0,
        walletInitParams(firstOwner.address, createEmptyCell()),
    );
    expect(overwrite).toHaveSuccessfulTx<RelayDeployWallet>({
        from: admin.address,
        to: collection.address,
    });
    expect(overwrite).toHaveFailedTx<DeployWallet>({
        from: collection.address,
        to: wallet.address,
        exitCode: Errors.AlreadyInitialized,
    });
    expect(wallet.getNftData().ownerAddress).toEqual(retryOwner.address);
    expect(collection.getCollectionData().nextWalletIndex).toEqual(1);
}

/// Starts the collection at the top index, because deploys up to 2^64 - 2 are not practical.
get fun `test collection: should stop deploying at the uint64 top`() {
    val deployer = testing.treasury("deployer");
    val owner = testing.treasury("owner");
    val collection = AgenticCollection.fromStorage(
        AgenticCollectionStorage.create(
            deployer.address,
            blockchain.globalId(),
            build("AgenticWallet"),
            emptyCollectionContent(),
            newRoyaltyParams(),
            {
                maxWalletIndex: MAX_WALLET_INDEX_UNLIMITED,
                publicDeployEnabled: true,
                deployPrice: TEST_DEPLOY_PRICE,
                referralBps: TEST_REFERRAL_BPS,
                traitSetCount: TEST_TRAIT_SET_COUNT,
            },
            MAX_WALLET_INDEX_UNLIMITED,
        ),
    );
    collection.deploy(deployer.address, { value: TEST_COLLECTION_DEPLOY_VALUE, bounce: false });
    expect(MAX_WALLET_INDEX_UNLIMITED).toEqual(0xFFFFFFFFFFFFFFFE);

    val last = deployWallet(
        collection,
        deployer.address,
        null,
        walletInitParams(owner.address, createEmptyCell()),
    );
    expect(last).toHaveSuccessfulTx<DeployWallet>({
        from: collection.address,
        to: collection.getNftAddressByIndex(MAX_WALLET_INDEX_UNLIMITED),
    });
    expect(collection.getCollectionData().nextWalletIndex).toEqual(MAX_WALLET_INDEX_UNLIMITED + 1);

    val autoPastTop = deployWallet(
        collection,
        deployer.address,
        null,
        walletInitParams(owner.address, createEmptyCell()),
    );
    expectWalletLimitReached(autoPastTop, deployer.address, collection.address);

    // the collection stores a cap below the next index
    val lowered = editSettings(collection, deployer.address, MAX_WALLET_INDEX_UNLIMITED - 1);
    expect(lowered).toHaveSuccessfulTx<EditCollectionSettings>({
        from: deployer.address,
        to: collection.address,
    });

    // a cap of 2^64 - 1 is storable, but a deploy at that index overflows the next index
    val uint64Max = editSettings(collection, deployer.address, MAX_WALLET_INDEX_UNLIMITED + 1);
    expect(uint64Max).toHaveSuccessfulTx<EditCollectionSettings>({
        from: deployer.address,
        to: collection.address,
    });
    val overflow = deployWallet(
        collection,
        deployer.address,
        null,
        walletInitParams(owner.address, createEmptyCell()),
    );
    expect(overflow).toHaveFailedTx<RelayDeployWallet>({
        from: deployer.address,
        to: collection.address,
        exitCode: 5,
    });
    expect(overflow).toNotHaveTx({ from: collection.address, deploy: true });
    expect(collection.getCollectionData().nextWalletIndex).toEqual(MAX_WALLET_INDEX_UNLIMITED + 1);
}

get fun `test collection: a deploy without an index should take the next index`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");

    var i = 0;
    while (i < 2) {
        val wallet = AgenticWallet.fromAddress(collection.getNftAddressByIndex(i));
        val result = deployWallet(
            collection,
            admin.address,
            null,
            walletInitParams(owner.address, createEmptyCell()),
        );

        expect(result).toHaveSuccessfulTx<DeployWallet>({
            from: collection.address,
            to: wallet.address,
        });
        expect(wallet.getNftData().ownerAddress).toEqual(owner.address);
        expect(collection.getCollectionData().nextWalletIndex).toEqual(i + 1);
        i += 1;
    }
}

get fun `test collection: a deploy without an index should respect the max wallet index`() {
    val (collection, admin, _) = setupTest(TEST_COLLECTION_DEPLOY_VALUE, "royaltyAddress", 0);
    val owner = testing.treasury("owner");
    deployWallet(
        collection,
        admin.address,
        null,
        walletInitParams(owner.address, createEmptyCell()),
    );
    expect(collection.getCollectionData().nextWalletIndex).toEqual(1);

    // closed: the max wallet index is the last deployed index
    val beforeClosed = snapshot(collection);
    val closed = deployWallet(
        collection,
        admin.address,
        null,
        walletInitParams(owner.address, createEmptyCell()),
    );
    expectWalletLimitReached(closed, admin.address, collection.address);
    expect(snapshot(collection)).toEqual(beforeClosed);
}

/// A failed deploy without an index still allocates an index. The next deploy without an index
/// gets a new index. Only an explicit index retries the failed one.
get fun `test collection: a deploy without an index after a failed one should get a new index`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val first = AgenticWallet.fromAddress(collection.getNftAddressByIndex(0));
    val second = AgenticWallet.fromAddress(collection.getNftAddressByIndex(1));

    val failed = deployWallet(collection, admin.address, null, invalidInitParams(owner.address));
    expect(failed).toHaveFailedTx<DeployWallet>({
        from: collection.address,
        to: first.address,
        exitCode: Errors.IncorrectForwardPayload,
    });
    expect(collection.getCollectionData().nextWalletIndex).toEqual(1);

    val auto = deployWallet(
        collection,
        admin.address,
        null,
        walletInitParams(owner.address, createEmptyCell()),
    );
    expect(auto).toHaveSuccessfulTx<DeployWallet>({
        from: collection.address,
        to: second.address,
    });
    expect(first.getNftData().isInitialized).toBeFalse();

    val retry = deployWallet(
        collection,
        admin.address,
        0,
        walletInitParams(owner.address, createEmptyCell()),
    );
    expect(retry).toHaveSuccessfulTx<DeployWallet>({ from: collection.address, to: first.address });
    expect(first.getNftData().isInitialized).toBeTrue();
    expect(collection.getCollectionData().nextWalletIndex).toEqual(2);
}

get fun `test collection: admin deploy action failure should bounce to the admin`() {
    val (collection, admin, _) = setupTest();
    val owner = testing.treasury("owner");
    val before = snapshot(collection);
    val balanceBefore = testing.getAccountBalance(collection.address);

    val result = collection.sendRelayDeployWallet(
        admin.address,
        0,
        null,
        balanceBefore + grams("1"),
        walletInitParams(owner.address, createEmptyCell()),
        { value: TEST_WALLET_DEPLOY_VALUE, bounce: true },
    );

    expect(result).toHaveTx<RelayDeployWallet>({
        from: admin.address,
        to: collection.address,
        exitCode: 0,
        success: false,
        actionExitCode: fun(code) {
            return code != 0;
        },
    });
    expect(result).toHaveTx({ from: collection.address, to: admin.address, bounced: true });
    expect(result).toNotHaveTx({ from: collection.address, deploy: true });
    expect(snapshot(collection)).toEqual(before);
    expect(testing.getAccountBalance(collection.address)).toBeGreaterOrEqual(balanceBefore);
}

get fun `test collection: should accept empty top-up`() {
    val (collection, _, _) = setupTest();
    val sender = testing.treasury("sender");
    val before = snapshot(collection);

    val result = collection.sendAny(
        sender.address,
        createEmptyCell(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    expect(result).toHaveSuccessfulTx({ from: sender.address, to: collection.address });
    expect(result).toNotHaveTx({ from: collection.address });
    expect(snapshot(collection)).toEqual(before);
}

/// The collection has no external handler, so it fails each external with exit code 11 (method
/// not found) before it accepts the message. This includes a well-formed admin message.
get fun `test collection: should not accept external messages`() {
    val (collection, _, _) = setupTest();
    val before = snapshot(collection);

    val empty = net.sendExternal(net.createExternalMessage(collection.address, createEmptyCell()));
    expect(empty).toBeNotAccepted();
    expect(empty).toHaveExternalVmExitCode(11);

    val adminOp = net.sendExternal(
        net.createExternalMessage(
            collection.address,
            ChangeCollectionAdmin {
                queryId: 0,
                newAdminAddress: randomAddress("external-admin"),
            },
        ),
    );
    expect(adminOp).toBeNotAccepted();
    expect(adminOp).toHaveExternalVmExitCode(11);

    expect(snapshot(collection)).toEqual(before);
}

get fun `test collection: get_nft_content should expand wallet index content`() {
    val (collection, admin, _) = setupTest();
    collection.sendEditCollectionContent(
        admin.address,
        0,
        newCollectionContent(),
        newRoyaltyParams(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    val marker = WalletIndexContent {}.toCell();
    expect(marker.hash()).toEqual(beginCell().storeUint(0x03, 8).endCell().hash());
    val markerWithRef = beginCell().storeUint(0x03, 8).storeRef(createEmptyCell()).endCell();

    expect(
        offchainUrl(
            collection.getNftContent(0, marker),
        ).equalTo("https://example.com/agents/0.json"),
    ).toBeTrue();
    expect(
        offchainUrl(
            collection.getNftContent(123, markerWithRef),
        ).equalTo("https://example.com/agents/123.json"),
    ).toBeTrue();
    expect(
        offchainUrl(
            collection.getNftContent(7, walletContent("")),
        ).equalTo("https://example.com/agents/7.json"),
    ).toBeTrue();
}

get fun `test collection: get_nft_content should expand trait set content`() {
    val (collection, admin, _) = setupTest();
    collection.sendEditCollectionContent(
        admin.address,
        0,
        newCollectionContent(),
        newRoyaltyParams(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    val first = TraitSetContent { traitSetIndex: 0 }.toCell();
    val last = TraitSetContent { traitSetIndex: 0xFFFF }.toCell();
    val withRef = beginCell()
        .storeUint(0x02, 8)
        .storeUint(119, 16)
        .storeRef(createEmptyCell())
        .endCell();

    expect(
        offchainUrl(
            collection.getNftContent(7, first),
        ).equalTo("https://example.com/agents/0/7.json"),
    ).toBeTrue();
    expect(
        offchainUrl(
            collection.getNftContent(0, last),
        ).equalTo("https://example.com/agents/65535/0.json"),
    ).toBeTrue();
    expect(
        offchainUrl(
            collection.getNftContent(123, withRef),
        ).equalTo("https://example.com/agents/119/123.json"),
    ).toBeTrue();
}

/// Only the admin can write such content: only the prefix sets the format.
get fun `test collection: get_nft_content should ignore extra bits and fail on a short trait set index`() {
    val (collection, admin, _) = setupTest();
    collection.sendEditCollectionContent(
        admin.address,
        0,
        newCollectionContent(),
        newRoyaltyParams(),
        { value: DEFAULT_MESSAGE_VALUE, bounce: true },
    );

    val indexWithExtraBits = beginCell().storeUint(0x03, 8).storeUint(0, 17).endCell();
    val traitSetWithExtraBits = beginCell()
        .storeUint(0x02, 8)
        .storeUint(5, 16)
        .storeUint(1, 1)
        .endCell();
    val traitSetWithoutIndex = beginCell().storeUint(0x02, 8).endCell();
    val traitSetWithShortIndex = beginCell().storeUint(0x02, 8).storeUint(0, 15).endCell();

    expect(
        offchainUrl(
            collection.getNftContent(7, indexWithExtraBits),
        ).equalTo("https://example.com/agents/7.json"),
    ).toBeTrue();
    expect(
        offchainUrl(
            collection.getNftContent(7, traitSetWithExtraBits),
        ).equalTo("https://example.com/agents/5/7.json"),
    ).toBeTrue();
    expect(
        net.runGetMethodExt<cell>(
            collection.address,
            "get_nft_content",
            [7, traitSetWithoutIndex],
        ),
    ).toHaveExitCode(9);
    expect(
        net.runGetMethodExt<cell>(
            collection.address,
            "get_nft_content",
            [7, traitSetWithShortIndex],
        ),
    ).toHaveExitCode(9);
}

get fun `test collection: get_nft_content should return other content as is`() {
    val (collection, _, _) = setupTest();
    val offchain = beginCell().storeUint(0x01, 8).storeString("ipfs://agent.json").endCell();
    val otherPrefixWithIndex = beginCell().storeUint(0x04, 8).storeUint(0, 16).endCell();
    val shorterThanPrefix = beginCell().storeUint(0, 4).endCell();
    val empty = createEmptyCell();

    expect(collection.getNftContent(0, otherPrefixWithIndex)).toEqual(otherPrefixWithIndex);
    expect(collection.getNftContent(0, shorterThanPrefix)).toEqual(shorterThanPrefix);

    expect(collection.getNftContent(0, offchain)).toEqual(offchain);
    expect(collection.getNftContent(0, empty)).toEqual(empty);
}

get fun `test collection: get_nft_address_by_index should match the wallet StateInit`() {
    val (collection, _, _) = setupTest();

    val walletIndexes = [0, 5, 0xFFFFFFFFFFFFFFFF];

    var i = 0;
    while (i < walletIndexes.size()) {
        val walletIndex = walletIndexes.get(i);
        val expected = AgenticWallet.fromStorage({
            walletIndex,
            collectionAddress: collection.address,
            seqno: 0,
        });
        expect(collection.getNftAddressByIndex(walletIndex)).toEqual(expected.address);
        i += 1;
    }
}

get fun `test collection: a masterchain collection should not deploy wallets`() {
    val deployer = testing.treasury("deployer");
    val collection = AgenticCollection.fromStorage(
        AgenticCollectionStorage.create(
            deployer.address,
            blockchain.globalId(),
            build("AgenticWallet"),
            emptyCollectionContent(),
            newRoyaltyParams(),
            {
                maxWalletIndex: MAX_WALLET_INDEX_UNLIMITED,
                publicDeployEnabled: true,
                deployPrice: TEST_DEPLOY_PRICE,
                referralBps: TEST_REFERRAL_BPS,
                traitSetCount: TEST_TRAIT_SET_COUNT,
            },
        ),
        null,
        MASTERCHAIN,
    );
    val deployRes = collection.deploy(
        deployer.address,
        { value: SETUP_DEPLOY_VALUE, bounce: false },
    );
    expect(deployRes).toHaveSuccessfulDeploy({ to: collection.address });

    val result = deployWallet(
        collection,
        deployer.address,
        null,
        walletInitParams(deployer.address, createEmptyCell()),
    );

    expect(result).toHaveFailedTx<RelayDeployWallet>({
        from: deployer.address,
        to: collection.address,
        exitCode: Errors.InvalidWorkchain,
    });
    expect(result).toNotHaveTx({ from: collection.address, deploy: true });
    expect(collection.getCollectionData().nextWalletIndex).toEqual(0);

    val publicResult = publicDeploy(collection, deployer.address, null, TEST_DEPLOY_VALUE);
    expect(publicResult).toHaveFailedTx<RelayPublicDeployWallet>({
        from: deployer.address,
        to: collection.address,
        exitCode: Errors.InvalidWorkchain,
    });
    expect(publicResult).toNotHaveTx({ from: collection.address, deploy: true });
    expect(collection.getCollectionData().nextWalletIndex).toEqual(0);
}
