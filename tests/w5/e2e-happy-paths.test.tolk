import "@acton/crypto"
import "@acton/ffi"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/big_array"

import "@contracts/messages"
import "@tests/fixtures"
import "@wrappers/AgenticWallet.gen"
import "@wrappers/send"
import "@wrappers/utils"

const W5_BENCH_KEY_SEED = 0x57550001
const W5_BENCH_NOW = 1000
const W5_BENCH_VALID_UNTIL = 2000

const W5_BENCH_TOP_UP_VALUE = grams("10")
const W5_BENCH_SIGNED_INTERNAL_VALUE = grams("0.1")
const W5_BENCH_OWNER_CALL_VALUE = grams("0.1")

const W5_BENCH_TRANSFER_VALUE = grams("1")
const W5_BENCH_OWNER_TRANSFER_VALUE = grams("0.001")

struct W5BenchFixture {
    wallet: AgenticWallet
    owner: Treasury
    receiver: Treasury
    keyPair: KeyPair
}

fun w5BenchKeyPair(): KeyPair {
    return crypto.seedToKeyPair(W5_BENCH_KEY_SEED as uint256);
}

fun w5BenchRawTransferMessage(dest: address, value: coins): cell {
    return beginCell()
        .storeUint(0x10, 6)
        .storeAddress(dest)
        .storeCoins(value)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeRef(createEmptyCell())
        .endCell();
}

fun w5BenchSendTxAction(dest: address, value: coins): SendMessageAction {
    return SendMessageAction {
        sendMode: SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
        outMsg: w5BenchRawTransferMessage(dest, value),
    };
}

fun w5BenchSendTxActions(dest: address, value: coins): array<SendMessageAction> {
    return [w5BenchSendTxAction(dest, value)];
}

/// Deploys the wallet with the seeded delegate key and tops it up.
fun deployW5BenchFixture(): W5BenchFixture {
    testing.setNow(W5_BENCH_NOW);

    val keyPair = w5BenchKeyPair();
    val receiver = testing.treasury("receiver");

    val (wallet, owner) = deployWalletWithKey(keyPair);

    val topUpResult = wallet.sendAny(
        owner.address,
        createEmptyCell(),
        { value: W5_BENCH_TOP_UP_VALUE },
    );
    topUpResult.giveName("setup top up AgenticWallet");

    expect(wallet.seqno()).toEqual(0);
    expect(wallet.getPublicKey()).toEqual(keyPair.publicKey);

    return W5BenchFixture { wallet, owner, receiver, keyPair };
}

fun sendW5BenchSignedExternal(
    fixture: W5BenchFixture,
    actions: array<SendMessageAction>,
): SendResultList {
    val seqno = fixture.wallet.seqno();
    val body = createExternalSignedRequest(
        fixture.keyPair,
        fixture.wallet.address,
        seqno,
        actions,
        W5_BENCH_VALID_UNTIL,
    );
    val msg = net.createExternalMessage(fixture.wallet.address, body);
    // measures only the external-in transaction of the wallet, then delivers its children
    val cursor = TxCursor {
        id: ffi.startMessageIter(
            msg.messageCell,
            address("-1:0000000000000000000000000000000000000000000000000000000000000000").toCell(),
        ),
    };
    val res = cursor.executeN(1);
    cursor.close();
    expect(fixture.wallet.seqno()).toEqual(seqno + 1);
    return res;
}

fun sendW5BenchSignedInternal(
    fixture: W5BenchFixture,
    actions: array<SendMessageAction>,
): SendResultList {
    val seqno = fixture.wallet.seqno();
    val body = createInternalSignedRequest(
        fixture.keyPair,
        fixture.wallet.address,
        seqno,
        actions,
        W5_BENCH_VALID_UNTIL,
    );
    val res = fixture
        .wallet
        .sendSignedRequest(
            fixture.owner.address,
            body,
            { value: W5_BENCH_SIGNED_INTERNAL_VALUE },
        );
    expect(fixture.wallet.seqno()).toEqual(seqno + 1);
    return res;
}

get fun `test w5 bench: deploy should set the seqno, delegate key and owner`() {
    val fixture = deployW5BenchFixture();

    expect(fixture.wallet.seqno()).toEqual(0);
    expect(fixture.wallet.getPublicKey()).toEqual(fixture.keyPair.publicKey);
    expect(fixture.wallet.getNftData().ownerAddress!).toEqual(fixture.owner.address);
}

get fun `test w5 bench: EXTERNAL transfer`() {
    val fixture = deployW5BenchFixture();
    val receiverBalanceBefore = testing.getAccountBalance(fixture.receiver.address);

    val res = sendW5BenchSignedExternal(
        fixture,
        w5BenchSendTxActions(fixture.receiver.address, W5_BENCH_TRANSFER_VALUE),
    );
    res.giveName("EXTERNAL transfer");

    expect(res.size()).toEqual(1);
    val outMessages = res.at(0).outMessages;
    expect(outMessages.size()).toEqual(1);

    val delivered = testing.processSingleTraceStep(
        fixture.wallet.address,
        OutMessage { messageCell: outMessages.atCell(0) },
    );
    val fee = delivered.tx.load().totalFees.grams;
    val receiverBalanceAfter = testing.getAccountBalance(fixture.receiver.address);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore + W5_BENCH_TRANSFER_VALUE - fee);
}

get fun `test w5 bench: INTERNAL transfer`() {
    val fixture = deployW5BenchFixture();
    val receiverBalanceBefore = testing.getAccountBalance(fixture.receiver.address);

    val res = sendW5BenchSignedInternal(
        fixture,
        w5BenchSendTxActions(fixture.receiver.address, W5_BENCH_TRANSFER_VALUE),
    );
    res.giveName("INTERNAL transfer");

    expect(res.size()).toEqual(2);
    expect(res).toHaveSuccessfulTx({
        from: fixture.owner.address,
        to: fixture.wallet.address,
        exitCode: 0,
    });
    expect(res).toHaveTx({
        from: fixture.wallet.address,
        to: fixture.receiver.address,
        value: W5_BENCH_TRANSFER_VALUE,
    });

    val fee = res.at(1).tx.load().totalFees.grams;
    val receiverBalanceAfter = testing.getAccountBalance(fixture.receiver.address);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore + W5_BENCH_TRANSFER_VALUE - fee);
}

/// The owner sets a new delegate key.
get fun `test w5 bench: SET delegate`() {
    val fixture = deployW5BenchFixture();
    val newDelegate = crypto.seedToKeyPair((W5_BENCH_KEY_SEED + 1) as uint256);

    val res = fixture
        .wallet
        .sendChangeWalletDelegate(
            fixture.owner.address,
            0,
            newDelegate.publicKey as uint256,
            { value: W5_BENCH_OWNER_CALL_VALUE, bounce: true },
        );
    res.giveName("SET delegate");

    expect(res.size()).toEqual(1);
    expect(res).toHaveSuccessfulTx<ChangeWalletDelegate>({
        from: fixture.owner.address,
        to: fixture.wallet.address,
    });
    expect(res.at(0).outMessages.size()).toEqual(0);
    expect(fixture.wallet.getPublicKey()).toEqual(newDelegate.publicKey);
}

/// The owner sends a transfer through an owner action.
get fun `test w5 bench: OWNER transfer`() {
    val fixture = deployW5BenchFixture();

    val receiverBalanceBefore = testing.getAccountBalance(fixture.receiver.address);
    val res = fixture
        .wallet
        .sendOwnerActions(
            fixture.owner.address,
            0,
            w5BenchSendTxActions(fixture.receiver.address, W5_BENCH_OWNER_TRANSFER_VALUE),
            { value: W5_BENCH_OWNER_CALL_VALUE },
        );
    res.giveName("OWNER transfer");

    expect(res.size()).toEqual(2);
    expect(res).toHaveSuccessfulTx({
        from: fixture.owner.address,
        to: fixture.wallet.address,
        exitCode: 0,
    });
    expect(res).toHaveTx({
        from: fixture.wallet.address,
        to: fixture.receiver.address,
        value: W5_BENCH_OWNER_TRANSFER_VALUE,
        exitCode: 0,
    });

    val fee = res.at(1).tx.load().totalFees.grams;
    val receiverBalanceAfter = testing.getAccountBalance(fixture.receiver.address);
    expect(receiverBalanceAfter).toEqual(
        receiverBalanceBefore + W5_BENCH_OWNER_TRANSFER_VALUE - fee,
    );
}
