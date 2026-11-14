import "@acton/emulation/network"

import "@contracts/messages"
import "@contracts/storage-wallet"
import "@tests/utils"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/send"
import "@wrappers/utils"

/// Current initialized storage of a wallet, read through its getters.
fun AgenticWallet.storage(self): AgenticWalletStorage {
    val data = self.getNftData();
    return {
        walletIndex: data.walletIndex,
        collectionAddress: data.collectionAddress,
        seqno: self.seqno(),
        ownerAddress: data.ownerAddress!,
        content: data.content!,
        delegatePublicKey: self.getPublicKey(),
    };
}

/// Replaces the wallet storage, to set states that a deploy can not make directly.
fun AgenticWallet.setStorage(self, storage: AgenticWalletStorage) {
    setActiveDataCell(self.address, storage.toCell());
}

/// Transactions of an accepted external message. Null if the wallet rejected it.
fun AgenticWallet.sendExternalSigned(self, request: ExternalSignedRequest): SendResultList? {
    return self.sendExternalSignedRequest(request).transactions;
}

/// A message from the wallet to itself, which a delegate uses to try to act as the owner.
fun selfMessageAction(wallet: AgenticWallet, body: cell): SendMessageAction {
    return sendMessageAction(wallet.address, grams("0.05"), body);
}

/// `ChangeWalletOwner` to `newOwnerAddress` with no excess recipient and an empty forward payload.
fun changeOwnerBody(newOwnerAddress: address): cell {
    return ChangeWalletOwner {
        queryId: 0,
        newOwnerAddress,
        sendExcessesTo: null,
        customPayload: null,
        forwardAmount: 0,
        forwardPayload: emptyForwardPayload().toCell().beginParse(),
    }.toCell();
}

/// One-element OutActionList with a reserve action, which the wallet must reject. A reserve
/// node has one ref, so it fails the node shape check (InvalidC5). The set-code cases reach the
/// action prefix check. TL-B: `action_reserve_currency#36e6b809 mode:uint8
/// currency:CurrencyCollection`.
fun reserveActionList(): OutActionsCell {
    return beginCell()
        .storeRef(createEmptyCell())
        .storeUint(0x36e6b809, 32)
        .storeUint(0, 8)
        .storeCoins(1)
        .storeBool(false)
        .endCell();
}

/// One-element OutActionList with an action that has the given prefix, mode and refs. Use it to
/// build actions other than send-message.
fun rawActionList(prefix: uint32, mode: uint8, extraRef: cell): OutActionsCell {
    return beginCell()
        .storeRef(createEmptyCell())
        .storeUint(prefix, 32)
        .storeUint(mode, 8)
        .storeRef(extraRef)
        .endCell();
}
