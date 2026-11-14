import "@acton/build"
import "@acton/crypto"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/messages"
import "@contracts/storage"
import "@contracts/storage-collection"
import "@tests/utils"
import "@wrappers/AgenticCollection.gen"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/utils"

// Collection

/// Referral share of `setupTest` collections, in basis points.
const TEST_REFERRAL_BPS = 1000

/// Number of trait sets that `setupTest` collections draw from.
const TEST_TRAIT_SET_COUNT = 120

/// Collection content with an empty metadata cell and an empty wallet content URL prefix.
fun emptyCollectionContent(): CollectionContent {
    return { collectionMetadata: createEmptyCell(), commonContent: "" };
}

/// Deploys a collection with the "deployer" treasury as admin. The collection address depends on
/// its storage, so calls in one test need different `royaltyName`s for different collections.
fun setupTest(
    deployValue: coins = TEST_COLLECTION_DEPLOY_VALUE,
    royaltyName: string = "royaltyAddress",
    maxWalletIndex: uint64 = MAX_WALLET_INDEX_UNLIMITED,
    publicDeployEnabled: bool = true,
    deployPrice: coins = TEST_DEPLOY_PRICE,
    referralBps: uint16 = TEST_REFERRAL_BPS,
    traitSetCount: uint16 = TEST_TRAIT_SET_COUNT,
): (AgenticCollection, Treasury, RoyaltyParams) {
    val deployer = testing.treasury("deployer");

    val royaltyParams = RoyaltyParams {
        numerator: 16,
        denominator: 2,
        royaltyAddress: randomAddress(royaltyName),
    };

    val nftCollection = AgenticCollection.fromStorage(
        AgenticCollectionStorage.create(
            deployer.address,
            blockchain.globalId(),
            build("AgenticWallet"),
            emptyCollectionContent(),
            royaltyParams,
            {
                maxWalletIndex,
                publicDeployEnabled,
                deployPrice,
                referralBps,
                traitSetCount,
            },
        ),
    );

    val deployRes = nftCollection.deploy(deployer.address, { value: deployValue, bounce: false });

    expect(deployRes).toHaveSuccessfulDeploy({
        to: nftCollection.address,
    });

    return (nftCollection, deployer, royaltyParams);
}

// Wallet deploys

/// Sends `RelayDeployWallet` for `walletIndex` (null: the next index). The default amounts are
/// the test amounts.
fun deployWallet(
    collection: AgenticCollection,
    sender: address,
    walletIndex: uint64?,
    initParams: AgenticWalletInitParams,
    attachAmount: coins = TEST_WALLET_ATTACH_AMOUNT,
    value: coins = TEST_WALLET_DEPLOY_VALUE,
): SendResultList {
    return collection.sendRelayDeployWallet(
        sender,
        0,
        walletIndex,
        attachAmount,
        initParams,
        { value, bounce: true },
    );
}

fun nftFixture(nftCollection: AgenticCollection, ownerAddress: address): AgenticWallet {
    val deployer = testing.treasury("deployer");
    val nextItemIndex = nftCollection.getCollectionData().nextWalletIndex;
    val nftDeployResult = deployWallet(
        nftCollection,
        deployer.address,
        null,
        walletInitParams(ownerAddress, createEmptyCell()),
    );

    expect(nftDeployResult).toHaveSuccessfulTx({
        from: deployer.address,
        to: nftCollection.address,
    });

    val nftAddress = nftCollection.getNftAddressByIndex(nextItemIndex);

    expect(nftDeployResult).toHaveSuccessfulDeploy({
        from: nftCollection.address,
        to: nftAddress,
    });

    return AgenticWallet.fromAddress(nftAddress);
}

/// Emulation only: deploys the next wallet of a shared collection with the given delegate key
/// (0: none). The "owner" treasury owns the wallet. Returns the wallet and its owner. The
/// collection starts at `firstWalletIndex`, so the wallet gets that index.
fun deployAgenticWalletWithKey(
    delegatePublicKey: uint256,
    firstWalletIndex: uint64 = 0,
): (AgenticWallet, Treasury) {
    val admin = testing.treasury("admin");
    val owner = testing.treasury("owner");

    val collection = AgenticCollection.fromStorage(
        AgenticCollectionStorage.create(
            admin.address,
            blockchain.globalId(),
            build("AgenticWallet"),
            emptyCollectionContent(),
            {
                numerator: 0,
                denominator: 1,
                royaltyAddress: admin.address,
            },
            {
                maxWalletIndex: MAX_WALLET_INDEX_UNLIMITED,
                publicDeployEnabled: false,
                deployPrice: SETUP_DEPLOY_PRICE,
                referralBps: 0,
                traitSetCount: 1,
            },
            firstWalletIndex,
        ),
    );
    collection
        .deploy(admin.address, { value: SETUP_DEPLOY_VALUE })
        .giveName("setup deploy collection");

    val walletIndex = collection.getCollectionData().nextWalletIndex;
    val walletAddress = collection.getNftAddressByIndex(walletIndex);
    val deployResult = collection.sendRelayDeployWallet(
        admin.address,
        0,
        null,
        SETUP_WALLET_ATTACH_AMOUNT,
        AgenticWalletInitParams.create(
            owner.address,
            createEmptyCell(),
            delegatePublicKey,
            0,
            emptyForwardPayload(),
        ),
        { value: SETUP_WALLET_DEPLOY_VALUE },
    );

    deployResult.giveName("setup deploy AgenticWallet");
    expect(deployResult).toHaveSuccessfulTx<DeployWallet>({ to: walletAddress });

    return (AgenticWallet.fromAddress(walletAddress), owner);
}

/// Deploys wallet `walletIndex` of `collectionAddress` from its StateInit without a `DeployWallet`
/// body. Anyone can do this before the collection deploys it. The account is then active but not
/// initialized.
fun deployUninitializedWallet(collectionAddress: address, walletIndex: uint64): AgenticWallet {
    val deployer = testing.treasury("uninitialized-wallet-deployer");
    val wallet = AgenticWallet.fromStorage({ walletIndex, collectionAddress, seqno: 0 });
    wallet.deploy(deployer.address, { value: SETUP_DEPLOY_VALUE, bounce: false });
    expect(wallet.getNftData().isInitialized).toBeFalse();
    return wallet;
}

/// Deploys a wallet with `keyPair` as the delegate key. Returns the wallet and its owner.
fun deployWalletWithKey(keyPair: KeyPair): (AgenticWallet, Treasury) {
    return deployAgenticWalletWithKey(keyPair.publicKey as uint256);
}

// Init params

/// Init params of a wallet deployed without a forward payload. By default, also without a
/// delegate key and without an owner notification.
fun walletInitParams(
    ownerAddress: address,
    content: cell,
    delegatePublicKey: uint256 = 0,
    forwardAmount: coins = 0,
): AgenticWalletInitParams {
    return AgenticWalletInitParams.create(
        ownerAddress,
        content,
        delegatePublicKey,
        forwardAmount,
        emptyForwardPayload(),
    );
}

// Keys

/// Key pair from `name`. The same name always gives the same key, so test runs are repeatable.
fun namedKeyPair(name: string): KeyPair {
    return crypto.seedToKeyPair(
        beginCell().storeSlice(name.beginParse()).endCell().hash() as uint256,
    );
}
