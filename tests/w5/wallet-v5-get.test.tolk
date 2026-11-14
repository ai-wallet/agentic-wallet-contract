import "@acton/testing/expect"

import "@tests/fixtures"
import "@wrappers/AgenticWallet.gen"
import "@tests/w5/utils"

/// The only storage injection: a real seqno of 12345 needs 12345 signed requests.
get fun `test w5: seqno getter should return the stored seqno`() {
    val expectedSeqno = 12345;
    val (wallet, _) = deployAgenticWalletWithKey(0);
    var storage = wallet.storage();
    storage.seqno = expectedSeqno;
    wallet.setStorage(storage);

    val actualSeqno = wallet.seqno();
    expect(actualSeqno).toEqual(expectedSeqno);
}

get fun `test w5: delegate key getter should return the deployed key`() {
    val expectedPublicKey = 0x1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF;

    val (wallet, _) = deployAgenticWalletWithKey(expectedPublicKey);

    val actualPublicKey = wallet.getPublicKey();
    expect(actualPublicKey).toEqual(expectedPublicKey);
}

/// The wallet index identifies wallets with the same delegate key.
get fun `test w5: wallet index should match the deployed index`() {
    val expectedWalletIndex = 12345;
    val (wallet, _) = deployAgenticWalletWithKey(0, expectedWalletIndex);

    val actualWalletIndex = wallet.getNftData().walletIndex;
    expect(actualWalletIndex).toEqual(expectedWalletIndex);
}

get fun `test w5: wallet index should default to 0`() {
    val (wallet, _) = deployAgenticWalletWithKey(0);

    val actualWalletIndex = wallet.getNftData().walletIndex;
    expect(actualWalletIndex).toEqual(0);
}

/// The owner is the only address that can send owner actions.
get fun `test w5: get_nft_data should return the owner address`() {
    val (wallet, owner) = deployAgenticWalletWithKey(0);

    val actual = wallet.getNftData().ownerAddress!;
    expect(actual).toEqual(owner.address);
}
