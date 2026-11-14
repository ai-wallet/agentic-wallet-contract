import "@stdlib/reflection"

import "@stdlib/strings"

import "@acton/build"
import "@acton/fmt"
import "@acton/io"
import "@acton/prompts"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/testing/assert"
import "@acton/types/big_array"
import "@acton/types/message"
import "@acton/types/transaction"

import "@contracts/fees"
import "@contracts/messages"
import "@contracts/storage"
import "@contracts/storage-collection"

import "@wrappers/AgenticCollection.gen"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/utils"

import "@scripts/utils/common"

// Constants

const DEFAULT_COLLECTION_NAME = "SomeNFT"
const DEFAULT_COLLECTION_DESCRIPTION = "Some NFT collection"
const DEFAULT_COLLECTION_IMAGE = "https://ton.org/assets/favicon.svg"
const DEFAULT_COMMON_CONTENT = "https://example.com/nft/"
const DEFAULT_TRAIT_SET_COUNT = 120

// Collection address

fun promptAgenticCollection(): AgenticCollection {
    return AgenticCollection.fromAddress(
        promptAgenticAddress("AGENTIC_COLLECTION", "Enter collection address"),
    );
}

// Metadata, royalty and settings

/// Prompts for the collection metadata. `current` (TEP-64 on-chain metadata) prefills the prompts.
/// A rebuild keeps only the 6 known keys.
fun promptAgenticCollectionInfo(current: cell? = null): AgenticCollectionInfo {
    val dict: map<uint256, Cell<OnchainText>> = current == null
        ? []
        : parseOnchainMetadata(current);
    return {
        name: promptAgenticString(
            "AGENTIC_COLLECTION_NAME",
            "Enter collection name",
            metadataText(dict, "name".sha256(), DEFAULT_COLLECTION_NAME),
        ),
        description: promptAgenticString(
            "AGENTIC_COLLECTION_DESCRIPTION",
            "Enter collection description",
            metadataText(dict, "description".sha256(), DEFAULT_COLLECTION_DESCRIPTION),
        ),
        image: promptAgenticString(
            "AGENTIC_COLLECTION_IMAGE",
            "Enter collection image URL",
            metadataText(dict, "image".sha256(), DEFAULT_COLLECTION_IMAGE),
        ),
        coverImage: promptOptionalText(
            "AGENTIC_COLLECTION_COVER_IMAGE",
            "Enter collection cover image URL (-: none)",
            metadataText(dict, "cover_image".sha256(), ""),
        ),
        externalLink: promptOptionalText(
            "AGENTIC_COLLECTION_EXTERNAL_LINK",
            "Enter collection website URL (-: none)",
            metadataText(dict, "external_link".sha256(), ""),
        ),
        socialLinks: promptOptionalText(
            "AGENTIC_COLLECTION_SOCIAL_LINKS",
            "Enter social links as JSON array text, for example [\"https://a\"] (-: none)",
            metadataText(dict, "social_links".sha256(), ""),
        ),
    };
}

/// Prefix of the wallet content URLs that the collection builds. A new prefix must end with "/".
/// The user can always keep `default`.
fun promptCommonContent(default: string): string {
    val prefix = promptAgenticString(
        "AGENTIC_COMMON_CONTENT",
        "Enter wallet content URL prefix (must end with \"/\")",
        default,
    );
    if (prefix.equalTo(default)) {
        return prefix;
    }
    var tail = prefix.beginParse();
    while (tail.remainingRefsCount() > 0) {
        tail = tail.preloadRef().beginParse();
    }
    if (tail.remainingBitsCount() < 8 || tail.getLastBits(8).preloadUint(8) != 0x2F) {
        Assert.fail("Wallet content URL prefix must end with \"/\"");
    }
    return prefix;
}

fun promptRoyaltyParams(default: RoyaltyParams): RoyaltyParams {
    val royalty: RoyaltyParams = {
        numerator: promptAgenticInt(
            "AGENTIC_ROYALTY_NUMERATOR",
            "Enter royalty numerator",
            default.numerator.toDecimalString(),
        ),
        denominator: promptAgenticInt(
            "AGENTIC_ROYALTY_DENOMINATOR",
            "Enter royalty denominator",
            default.denominator.toDecimalString(),
        ),
        royaltyAddress: promptAgenticAddress(
            "AGENTIC_ROYALTY_ADDRESS",
            "Enter royalty address",
            default.royaltyAddress,
        ),
    };
    // no on-chain check limits the share
    if (royalty.denominator == 0) {
        Assert.fail("Royalty denominator must be positive");
    }
    if (royalty.numerator > royalty.denominator) {
        Assert.fail("Royalty numerator must not exceed the denominator");
    }
    return royalty;
}

/// Prompts for the collection settings, prefilled from `default`.
fun promptCollectionSettings(default: CollectionSettingsReply): CollectionSettingsReply {
    val maxWalletIndex = promptAgenticInt(
        "AGENTIC_MAX_WALLET_INDEX",
        "Enter max wallet index (highest index a new wallet may get)",
        default.maxWalletIndex.toDecimalString(),
    );
    // a cap of 2^64 - 1 is storable, but a deploy at that index overflows the next index
    if (maxWalletIndex < 0 || maxWalletIndex > MAX_WALLET_INDEX_UNLIMITED) {
        Assert.fail(
            format("Max wallet index must be between 0 and {}", MAX_WALLET_INDEX_UNLIMITED),
        );
    }
    val publicDeployEnabled = confirm(
        "Allow anyone to deploy wallets (public deploys)?",
        envBool("AGENTIC_PUBLIC_DEPLOY_ENABLED") ?? default.publicDeployEnabled,
        "anyone may deploy a wallet at the deploy price",
    );
    val deployPrice = promptGrams(
        "AGENTIC_DEPLOY_PRICE",
        "Enter public deploy price",
        default.deployPrice,
    );
    val referralBps = promptAgenticInt(
        "AGENTIC_REFERRAL_BPS",
        format(
            "Enter referral share of the deploy price, in basis points (0-{})",
            REFERRAL_BPS_DENOMINATOR,
        ),
        default.referralBps.toDecimalString(),
    );
    // no on-chain check limits the share
    if (referralBps < 0 || referralBps > REFERRAL_BPS_DENOMINATOR) {
        Assert.fail(
            format(
                "Referral share must be between 0 and {} basis points",
                REFERRAL_BPS_DENOMINATOR,
            ),
        );
    }
    // no on-chain check limits the price: a public deploy must pay its costs after the referral
    val netDeployPrice = deployPrice - referralReward(deployPrice, referralBps);
    if (publicDeployEnabled && netDeployPrice < MIN_NET_DEPLOY_PRICE) {
        Assert.fail(
            format(
                "Deploy price minus the referral share must be at least {} GRAM",
                formatGramsInput(MIN_NET_DEPLOY_PRICE),
            ),
        );
    }
    val traitSetCount = promptAgenticInt(
        "AGENTIC_TRAIT_SET_COUNT",
        "Enter number of trait sets a public deploy draws from",
        default.traitSetCount.toDecimalString(),
    );
    // no on-chain check limits the count: the collection can store 0, but it draws like 1
    if (traitSetCount < 1 || traitSetCount > MAX_TRAIT_SET_COUNT) {
        Assert.fail(
            format("Trait set count must be between 1 and {}", MAX_TRAIT_SET_COUNT),
        );
    }
    return {
        maxWalletIndex,
        publicDeployEnabled,
        deployPrice,
        referralBps,
        traitSetCount,
    };
}

// Storage

fun makeAgenticCollectionStorage(
    admin: address,
    info: AgenticCollectionInfo,
    commonContent: string,
    royalty: RoyaltyParams,
    settings: CollectionSettingsReply,
): AgenticCollectionStorage {
    return AgenticCollectionStorage.create(
        admin,
        targetGlobalId(),
        build("AgenticWallet"),
        { collectionMetadata: buildOnchainMetadata(info), commonContent },
        royalty,
        settings,
    );
}

/// Collection storage from the account state. It includes fields that no getter returns.
fun fetchCollectionStorage(collectionAddress: address): AgenticCollectionStorage {
    val account = scripts.fetchAccountState(collectionAddress);
    if (account == null) {
        Assert.fail("Collection account not found");
    }
    val state = account.storage.state;
    if (state !is TlbAccountStateActive) {
        Assert.fail("Collection account is not active");
    }
    return AgenticCollectionStorage.fromCell(state.stateInit.data!);
}

// Deploys

fun deployAgenticCollection(
    admin: ActonWallet,
    storage: AgenticCollectionStorage,
    value: coins,
): AgenticCollection {
    val collection = AgenticCollection.fromStorage(storage);
    collection.deploy(admin.address, { value, bounce: false }).confirm();
    return collection;
}

/// Wallet index to deploy. Empty (null) lets the collection select the next index. An earlier
/// index retries a failed deploy.
fun promptWalletIndex(): uint64? {
    val input = promptAgenticString(
        "AGENTIC_WALLET_INDEX",
        "Enter wallet index (empty: next index; an earlier one retries a failed deploy)",
        "",
    );
    if (input.calculateLength() == 0) {
        return null;
    }
    return parseIntInput(input, "AGENTIC_WALLET_INDEX");
}

/// Sends `RelayDeployWallet` for `walletIndex` (null: the next index). Returns the wallet from
/// the trace, so a null index needs no lookup.
fun deployAgenticWallet(
    collection: AgenticCollection,
    admin: ActonWallet,
    walletIndex: uint64?,
    attachAmount: coins,
    initParams: AgenticWalletInitParams,
    value: coins,
): AgenticWallet {
    return deployedAgenticWallet(
        collection,
        collection
            .sendRelayDeployWallet(
                admin.address,
                newQueryId(),
                walletIndex,
                attachAmount,
                initParams,
                { value, bounce: true },
            )
            .confirm(),
    );
}

/// Deploys the next wallet for `requester` at the collection price. Returns the deployed wallet.
fun publicDeployAgenticWallet(
    collection: AgenticCollection,
    requester: ActonWallet,
    referralAddress: address?,
    value: coins,
): AgenticWallet {
    return deployedAgenticWallet(
        collection,
        collection
            .sendRelayPublicDeployWallet(
                requester.address,
                newQueryId(),
                referralAddress,
                { value, bounce: true },
            )
            .confirm(),
    );
}

/// The wallet the collection deployed in `trace`. The loop reads the list itself:
/// `findTransaction` searches only local emulations, so it finds nothing in a broadcast trace
/// (Acton 1.2.1).
fun deployedAgenticWallet(collection: AgenticCollection, trace: SendResultList): AgenticWallet {
    val prefix = reflect.serializationPrefixOf<DeployWallet>();
    var i = 0;
    while (i < trace.size()) {
        val result = trace.get(i);
        val message = inMsg(result);
        val info = message.info;
        if (info is TlbInternalMessage && !info.bounced && info.src == collection.address) {
            val body = message.loadBody();
            if (body.remainingBitsCount() >= prefix.1 && body.preloadUint(prefix.1) == prefix.0) {
                return AgenticWallet.fromAddress(result.tx.load().getAccountAddress());
            }
        }
        i += 1;
    }
    Assert.fail("No wallet deploy in the trace");
}

// Info

fun printAgenticCollectionInfo(collection: AgenticCollection) {
    val data = collection.getCollectionData();
    val royalty = collection.royaltyParams();
    println("AGENTIC_COLLECTION={}", collection.address);
    println("AGENTIC_ADMIN={}", data.adminAddress);
    println("AGENTIC_NEXT_WALLET_INDEX={}", data.nextWalletIndex);
    val settings = collection.getCollectionSettings();
    println("AGENTIC_MAX_WALLET_INDEX={}", settings.maxWalletIndex);
    println("AGENTIC_PUBLIC_DEPLOY_ENABLED={}", settings.publicDeployEnabled);
    println("AGENTIC_DEPLOY_PRICE={}", formatGramsInput(settings.deployPrice));
    println("AGENTIC_REFERRAL_BPS={}", settings.referralBps);
    println("AGENTIC_TRAIT_SET_COUNT={}", settings.traitSetCount);
    println("AGENTIC_COLLECTION_METADATA_HASH={}", data.collectionMetadata.hash());
    val storage = fetchCollectionStorage(collection.address);
    println("AGENTIC_COMMON_CONTENT={}", storage.content.load().commonContent);
    println("AGENTIC_ROYALTY_ADDRESS={}", royalty.royaltyAddress);
    println("AGENTIC_ROYALTY_NUMERATOR={}", royalty.numerator);
    println("AGENTIC_ROYALTY_DENOMINATOR={}", royalty.denominator);
    println("AGENTIC_BALANCE={:gram}", scripts.fetchAccountBalance(collection.address));
}
