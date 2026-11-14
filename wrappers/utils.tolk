// Client helpers for scripts and tests. A dApp port must mirror this file.

import "@stdlib/strings"

import "@acton/crypto"

import "@contracts/AgenticWallet"
import "@contracts/fees"
import "@contracts/messages"
import "@contracts/storage"
import "@contracts/storage-collection"
import "@contracts/wallet-content"

// Amounts and limits

/// Highest `maxWalletIndex` at which every permitted deploy works. With a cap of 2^64 - 1, a
/// deploy at that index overflows `nextWalletIndex`.
const MAX_WALLET_INDEX_UNLIMITED = 18446744073709551614

/// Highest `traitSetCount`: the field is a uint16.
const MAX_TRAIT_SET_COUNT = 0xFFFF

// off-chain amounts for scripts and tests; tests/utils.tolk has the test amounts and
// contracts/fees.tolk has the on-chain amounts

// script defaults: a wallet deploy pays the storage reserve and the owner notification. An admin
// deploy also has space for a long forward comment or URL.
const DEFAULT_MESSAGE_VALUE = grams("0.001")
const DEFAULT_DEPLOY_VALUE = grams("0.025")
const DEFAULT_DEPLOY_MESSAGE_VALUE = grams("0.015")
const DEFAULT_WALLET_ATTACH_AMOUNT = grams("0.012")
/// More than the collection minimum, which gives a margin for higher forward fees.
const DEFAULT_WALLET_LEFTOVER = MIN_WALLET_STORAGE + WALLET_DEPLOY_FEES
const DEFAULT_DEPLOY_PRICE = grams("0.05")
/// A payment from the wallet balance, not a fee.
const DEFAULT_TRANSFER_AMOUNT = grams("0.01")
/// Lowest deploy price minus the referral share. It pays the wallet deploy fees and the collection
/// fees.
const MIN_NET_DEPLOY_PRICE = grams("0.003")

/// Referral share of the deploy price, rounded down in the same way as the collection does it.
fun referralReward(deployPrice: coins, referralBps: int): coins {
    return mulDivFloor(deployPrice, referralBps, REFERRAL_BPS_DENOMINATOR);
}

// Wallet content and comments

/// Text comment body (op 0). An empty text gives no body. If the first cell of the text does not
/// fit after the op, the text continues in a ref. This is still a valid snake format.
fun commentBody(text: string): cell? {
    if (text.calculateLength() == 0) {
        return null;
    }
    var body = beginCell().storeUint(0, 32);
    if (text.beginParse().remainingBitsCount() <= 1023 - 32) {
        return body.storeSlice(text.beginParse()).endCell();
    }
    return body.storeRef(text as unknown as cell).endCell();
}

/// Empty `url`: `WalletIndexContent`, which the collection expands to
/// "<commonContent><index>.json". Other `url`: TEP-64 off-chain content.
fun walletContent(url: string): cell {
    if (url.calculateLength() == 0) {
        return WalletIndexContent {}.toCell();
    }
    return url.prefixWith01() as unknown as cell;
}

/// TEP-64 off-chain content: 0x01, then the URL in a ref (the layout of `walletContent`).
struct (0x01) UrlContent {
    url: string
}

/// Wallet content with a value to read back: a trait set index or a URL. Other content is index
/// content.
type PrefillContent = TraitSetContent | UrlContent

// Collection storage and metadata (TEP-64 on-chain)

/// Storage of a new collection. `networkId` is the global ID of the target network.
fun AgenticCollectionStorage.create(
    adminAddress: address,
    networkId: int32,
    walletCode: cell,
    content: CollectionContent,
    royalty: RoyaltyParams,
    settings: CollectionSettingsReply,
    nextWalletIndex: uint64 = 0,
): AgenticCollectionStorage {
    return {
        nextWalletIndex,
        maxWalletIndex: settings.maxWalletIndex,
        publicDeployEnabled: settings.publicDeployEnabled,
        deployPrice: settings.deployPrice,
        referralBps: settings.referralBps,
        traitSetCount: settings.traitSetCount,
        networkId,
        adminAddress,
        content: content.toCell(),
        walletCode,
        royaltyParams: royalty.toCell(),
    };
}

const ONCHAIN_CONTENT_PREFIX = 0x00

/// Collection metadata. Empty `coverImage`, `externalLink` and `socialLinks` are not stored.
struct AgenticCollectionInfo {
    name: string
    description: string
    image: string
    coverImage: string
    externalLink: string
    /// JSON array text, for example `["https://a","https://b"]`
    socialLinks: string
}

/// TEP-64 text value: 0x00, then the text in a ref (the layout of `prefixWith00`).
struct (0x00) OnchainText {
    text: string
}

fun buildOnchainMetadata(info: AgenticCollectionInfo): cell {
    var dict: map<uint256, string_prefixed0x> = [];
    dict.set("name".sha256(), info.name.prefixWith00());
    dict.set("description".sha256(), info.description.prefixWith00());
    dict.set("image".sha256(), info.image.prefixWith00());
    if (info.coverImage.calculateLength() != 0) {
        dict.set("cover_image".sha256(), info.coverImage.prefixWith00());
    }
    if (info.externalLink.calculateLength() != 0) {
        dict.set("external_link".sha256(), info.externalLink.prefixWith00());
    }
    if (info.socialLinks.calculateLength() != 0) {
        dict.set("social_links".sha256(), info.socialLinks.prefixWith00());
    }
    return beginCell()
        .storeUint(ONCHAIN_CONTENT_PREFIX, 8)
        .storeDict(dict.toLowLevelDict())
        .endCell();
}

/// Key map of TEP-64 on-chain metadata: the content without its 0x00 prefix.
fun parseOnchainMetadata(metadata: cell): map<uint256, Cell<OnchainText>> {
    return metadata.beginParse().skipBits(8).loadAny();
}

/// Text of metadata key `keyHash`, else `default`.
fun metadataText(dict: map<uint256, Cell<OnchainText>>, keyHash: uint256, default: string): string {
    val found = dict.get(keyHash);
    return found.isFound ? found.loadValue().load().text : default;
}

// Forward payload and wallet init params

/// Empty forward payload, stored inline (only the Either bit 0).
fun emptyForwardPayload(): PayloadInline {
    return { value: createEmptySlice() };
}

/// True if `payload` fits inline in `base`, the cell with an empty payload. The Either prefix bit
/// takes 1 bit.
fun payloadFitsInline(base: cell, payload: slice): bool {
    val (baseBits, baseRefs) = base.beginParse().remainingBitsAndRefsCount();
    return (1023 - baseBits - 1) >= payload.remainingBitsCount() &&
        (4 - baseRefs) >= payload.remainingRefsCount();
}

/// Wallet init params for `AgenticCollection.sendRelayDeployWallet`. Stores `forwardPayload`
/// with its Either prefix bit, which the wallet requires.
fun AgenticWalletInitParams.create(
    ownerAddress: address,
    content: cell,
    delegatePublicKey: uint256,
    forwardAmount: coins,
    forwardPayload: PayloadInline | PayloadInRef,
): AgenticWalletInitParams {
    return {
        ownerAddress,
        content,
        delegatePublicKey,
        forwardAmount,
        forwardPayload: forwardPayload.toCell().beginParse(),
    };
}

/// Init params with `forwardPayload` inline if it fits in the cell, or in a ref.
fun AgenticWalletInitParams.createPayloadAuto(
    ownerAddress: address,
    content: cell,
    delegatePublicKey: uint256,
    forwardAmount: coins,
    forwardPayload: slice,
): AgenticWalletInitParams {
    val fitsInline = payloadFitsInline(
        AgenticWalletInitParams {
            ownerAddress,
            content,
            delegatePublicKey,
            forwardAmount,
            forwardPayload: createEmptySlice(),
        }.toCell(),
        forwardPayload,
    );

    return fitsInline
        ? AgenticWalletInitParams.create(
            ownerAddress,
            content,
            delegatePublicKey,
            forwardAmount,
            PayloadInline { value: forwardPayload },
        )
        : AgenticWalletInitParams.create(
            ownerAddress,
            content,
            delegatePublicKey,
            forwardAmount,
            PayloadInRef { value: forwardPayload.toCell() },
        );
}

// Out actions

/// One send-message action of an OutActionList.
struct SendMessageAction {
    sendMode: uint8
    outMsg: cell
}

/// Non-bounceable transfer with an optional body. The default mode includes ignore-errors (+2),
/// so external requests can also use it.
fun sendMessageAction(
    dest: address,
    value: coins,
    body: cell? = null,
    sendMode: uint8 = SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
): SendMessageAction {
    // a nullable `body` would serialize differently from no body
    if (body == null) {
        return { sendMode, outMsg: createMessage({ bounce: false, value, dest }).messageCell };
    }
    val outMsg = createMessage({
        bounce: false,
        value,
        dest,
        body,
    });
    return { sendMode, outMsg: outMsg.messageCell };
}

/// Builds an OutActionList. Its actions run in array order. An empty array gives an empty list.
/// No validation: the contract rejects invalid lists.
fun buildOutActions(actions: array<SendMessageAction>): OutActionsCell {
    var list = createEmptyCell();
    var i = 0;
    while (i < actions.size()) {
        val action = actions.get(i);
        list = OutActionWithSendMessageOnly {
            prev: list as Cell<OutActionWithSendMessageOnlyOrEmpty>,
            sendMode: action.sendMode,
            outMsg: action.outMsg,
        }.toCell();
        i += 1;
    }
    return list;
}

// Signed requests

/// Signs everything in `request` except its trailing signature, as the contract checks it.
fun signRequest(keyPair: KeyPair, request: cell): bits512 {
    var signedSlice = request.beginParse();
    signedSlice.removeLastBits(SIZE_SIGNATURE);
    return crypto.rawSign(keyPair.privateKey, signedSlice.hash()) as bits512;
}

/// 512-bit zero signature, so a request serializes to its final layout before signing.
fun placeholderSignature(): bits512 {
    return beginCell().storeUint(0, 256).storeUint(0, 256).toSlice() as bits512;
}

/// Signed internal request. A null `validUntil` gives a time shortly after now.
fun createInternalSignedRequest(
    keyPair: KeyPair,
    walletAddress: address,
    seqno: uint32,
    outActions: array<SendMessageAction>,
    validUntil: uint32? = null,
): InternalSignedRequest {
    return createInternalSignedRequestRaw(
        keyPair,
        walletAddress,
        seqno,
        buildOutActions(outActions),
        validUntil,
    );
}

/// Signed internal request with a raw OutActionList, for lists that the helpers can not build.
fun createInternalSignedRequestRaw(
    keyPair: KeyPair,
    walletAddress: address,
    seqno: uint32,
    outActions: OutActionsCell,
    validUntil: uint32? = null,
): InternalSignedRequest {
    var request: InternalSignedRequest = {
        walletAddress,
        validUntil: validUntil ?? blockchain.now() + 1000,
        seqno,
        outActions,
        signature: placeholderSignature(),
    };
    request.signature = signRequest(keyPair, request.toCell());
    return request;
}

/// Signed external request. A null `validUntil` gives a time shortly after now.
fun createExternalSignedRequest(
    keyPair: KeyPair,
    walletAddress: address,
    seqno: uint32,
    outActions: array<SendMessageAction>,
    validUntil: uint32? = null,
): ExternalSignedRequest {
    return createExternalSignedRequestRaw(
        keyPair,
        walletAddress,
        seqno,
        buildOutActions(outActions),
        validUntil,
    );
}

/// Signed external request with a raw OutActionList, for lists that the helpers can not build.
fun createExternalSignedRequestRaw(
    keyPair: KeyPair,
    walletAddress: address,
    seqno: uint32,
    outActions: OutActionsCell,
    validUntil: uint32? = null,
): ExternalSignedRequest {
    var request: ExternalSignedRequest = {
        walletAddress,
        validUntil: validUntil ?? blockchain.now() + 1000,
        seqno,
        outActions,
        signature: placeholderSignature(),
    };
    request.signature = signRequest(keyPair, request.toCell());
    return request;
}
