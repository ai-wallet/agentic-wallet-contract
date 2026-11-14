import "@scripts/utils/common"
import "@scripts/utils/wallet"

fun main() {
    printNetwork();
    printAgenticWalletInfo(promptAgenticWallet());
}
