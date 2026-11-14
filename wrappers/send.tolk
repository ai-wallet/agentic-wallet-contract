// Acton send methods for scripts and tests. A dApp does not mirror them: it sends the same
// message bodies, which utils.tolk builds.

import "@acton/emulation/network"

import "@contracts/messages"

import "AgenticWallet.gen"

import "utils"

/// Sends `ChangeWalletOwner` with `forwardPayload` inline.
fun AgenticWallet.sendChangeWalletOwnerPayloadInline(
    self,
    from: address,
    queryId: uint64,
    newOwnerAddress: address,
    sendExcessesTo: address?,
    customPayload: cell?,
    forwardAmount: coins,
    forwardPayload: slice,
    config: SendParams = {},
): SendResultList {
    return self.sendChangeWalletOwner(
        from,
        queryId,
        newOwnerAddress,
        sendExcessesTo,
        customPayload,
        forwardAmount,
        PayloadInline { value: forwardPayload },
        config,
    );
}

/// Sends `ChangeWalletOwner` with `forwardPayload` in a ref.
fun AgenticWallet.sendChangeWalletOwnerPayloadInRef(
    self,
    from: address,
    queryId: uint64,
    newOwnerAddress: address,
    sendExcessesTo: address?,
    customPayload: cell?,
    forwardAmount: coins,
    forwardPayload: cell,
    config: SendParams = {},
): SendResultList {
    return self.sendChangeWalletOwner(
        from,
        queryId,
        newOwnerAddress,
        sendExcessesTo,
        customPayload,
        forwardAmount,
        PayloadInRef { value: forwardPayload as Cell<RemainingBitsAndRefs> },
        config,
    );
}

/// Sends `ChangeWalletOwner` with `forwardPayload` inline if it fits in the body, or in a ref.
fun AgenticWallet.sendChangeWalletOwnerPayloadAuto(
    self,
    from: address,
    queryId: uint64,
    newOwnerAddress: address,
    sendExcessesTo: address?,
    customPayload: cell?,
    forwardAmount: coins,
    forwardPayload: slice,
    config: SendParams = {},
): SendResultList {
    val fitsInline = payloadFitsInline(
        ChangeWalletOwner {
            queryId,
            newOwnerAddress,
            sendExcessesTo,
            customPayload,
            forwardAmount,
            forwardPayload: createEmptySlice(),
        }.toCell(),
        forwardPayload,
    );

    return fitsInline
        ? self.sendChangeWalletOwnerPayloadInline(
            from,
            queryId,
            newOwnerAddress,
            sendExcessesTo,
            customPayload,
            forwardAmount,
            forwardPayload,
            config,
        )
        : self.sendChangeWalletOwnerPayloadInRef(
            from,
            queryId,
            newOwnerAddress,
            sendExcessesTo,
            customPayload,
            forwardAmount,
            forwardPayload.toCell(),
            config,
        );
}

fun AgenticWallet.sendSignedRequest(
    self,
    from: address,
    request: InternalSignedRequest,
    config: SendParams = {},
): SendResultList {
    return self.sendAny(from, request.toCell(), config);
}

fun AgenticWallet.sendExternalSignedRequest(
    self,
    request: ExternalSignedRequest,
): ExternalSendResult {
    return self.sendAnyExternal(request.toCell());
}

fun AgenticWallet.sendOwnerActions(
    self,
    from: address,
    queryId: uint64,
    outActions: array<SendMessageAction>,
    config: SendParams = {},
): SendResultList {
    val request: OwnerActionRequest = { queryId, outActions: buildOutActions(outActions) };
    return self.sendAny(from, request.toCell(), config);
}
