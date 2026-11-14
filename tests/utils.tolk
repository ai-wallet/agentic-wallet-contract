import "@stdlib/gas-payments"

import "@acton/emulation/config"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/tlb/maybe"
import "@acton/types/message"
import "@acton/types/transaction"

import "@wrappers/AgenticWallet.gen"

// Amounts

// test collections and wallet deploys
const TEST_DEPLOY_PRICE = grams("0.1")
/// Value of a public deploy: the deploy price plus the wallet leftover.
const TEST_DEPLOY_VALUE = TEST_DEPLOY_PRICE + grams("0.05")
const TEST_COLLECTION_DEPLOY_VALUE = grams("0.05")
/// Admin deploy: the value sent to the wallet.
const TEST_WALLET_ATTACH_AMOUNT = grams("0.015")
/// Admin deploy: the message value.
const TEST_WALLET_DEPLOY_VALUE = grams("0.05")

// large setup amounts for tests that do not check funding
const SETUP_DEPLOY_PRICE = grams("1")
/// Value of a deploy from StateInit only (collection, uninitialized wallet).
const SETUP_DEPLOY_VALUE = grams("1")
const SETUP_WALLET_ATTACH_AMOUNT = grams("5")
const SETUP_WALLET_DEPLOY_VALUE = grams("6")

// Texts

/// The longest URL or comment that the script default amounts can pay for.
const SCRIPT_SIZED_TEXT = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abc"

// Emulator state

fun activeShardAccount(addr: address): TlbShardAccount {
    val shard = testing.getShardAccount(addr);
    if (shard != null) {
        return shard;
    }
    Assert.fail("Expected TlbShardAccount when setting data");
}

fun setActiveDataCell(addr: address, newData: cell) {
    var updatedShard = activeShardAccount(addr);
    val account = updatedShard.account.load();
    if (account !is TlbAccountInfo) {
        Assert.fail("Expected TlbAccountInfo when setting data");
    }
    var info = account;
    if (info.storage.state !is TlbAccountStateActive) {
        Assert.fail("Expected TlbAccountStateActive when setting data");
    }

    var active = info.storage.state;
    active.stateInit.data = newData;
    info.storage.state = active;
    updatedShard.account = (info as TlbAccount).toCell();
    testing.setShardAccount(addr, updatedShard);
}

// Fee estimates

/// `in.originalForwardFee` of the first transaction that matches `params`: the forward fee that
/// its sender paid for the incoming message.
fun originalForwardFee(result: SendResultList, params: SearchParams): coins {
    val info = result.findTransaction(params)!.loadInMsg<RemainingBitsAndRefs>().info;
    assert (info is TlbInternalMessage) throw 0xFFFF;

    // check-disable-next-line deprecated-symbol-use
    return calculateOriginalForwardFee(BASECHAIN, info.forwardFee);
}

/// Gas and storage fees of an ordinary transaction: what the account pays in addition to its
/// sends.
fun gasAndStorageFees(tx: TlbTransaction): coins {
    val description = tx.description.load();
    assert (description is TlbTransOrd) throw 0xFFFF;

    var fees: coins = 0;
    val storagePhase = description.storagePh.unwrapOr(null);
    if (storagePhase != null) {
        fees += storagePhase.storageFeesCollected;
    }
    if (description.computePh is TlbTrComputeVm) {
        fees += description.computePh.gasFees;
    }
    return fees;
}

fun estimateMessageForwardFee<T>(body: T, dest: address, bounce: bool, value: coins): coins {
    val outgoingMessage = createMessage({
        body,
        dest,
        bounce,
        value,
    });
    val totalForwardFee = outgoingMessage.estimateFeeWithoutSending(SEND_MODE_REGULAR);
    val prices = testing.getConfig().getMsgForwardPrices(BASECHAIN);
    val firstPart = (totalForwardFee * prices.firstFrac) / 65536;
    val remainingForwardFee = totalForwardFee - firstPart;

    // check-disable-next-line deprecated-symbol-use
    return calculateOriginalForwardFee(BASECHAIN, remainingForwardFee);
}

// Checks

fun expectFrozen(addr: address) {
    val account = testing.getAccountState(addr);
    expect(account != null).toBeTrue();
    expect(account!.storage.state is TlbAccountStateFrozen).toBeTrue();
}

/// Expects that the account at `addr` is not an initialized wallet. The account can exist or not.
fun expectNotInitialized(addr: address) {
    if (testing.isDeployed(addr)) {
        expect(AgenticWallet.fromAddress(addr).getNftData().isInitialized).toBeFalse();
    }
}

/// Sends `body` as an external and expects the wallet to reject it with `exitCode` before it
/// accepts the message. There is no transaction, so only the emulator exit code tells why.
fun AgenticWallet.expectExternalRejected(self, body: cell, exitCode: int) {
    val result = self.sendAnyExternal(body);
    expect(result.transactions == null).toBeTrue();
    expect(result.error!.vmExitCode!).toEqual(exitCode);
}

/// Hash of the current data cell of the wallet. Works for initialized and uninitialized wallets.
fun AgenticWallet.dataHash(self): int {
    val account = testing.getAccountState(self.address);
    if (account == null || account.storage.state !is TlbAccountStateActive) {
        Assert.fail("Expected an active wallet account");
    }
    return account.storage.state.stateInit.data!.hash();
}

/// Expects the wallet to accept a message from `from` without side effects. The transaction
/// succeeds, the wallet sends nothing and its data does not change.
fun AgenticWallet.expectIgnored(self, receipt: SendResultList, from: address, dataHashBefore: int) {
    expect(receipt).toHaveSuccessfulTx({ from, to: self.address, exitCode: 0 });
    expect(receipt).toNotHaveTx({ from: self.address });
    expect(self.dataHash()).toEqual(dataHashBefore);
}
