# Agentic Wallet

Smart contracts for the Agentic Wallet on the TON blockchain. Each wallet is an item of an NFT collection.

- Written in Tolk and built with the Acton toolchain.
- TEP-62 NFT collection and items, TEP-64 metadata, TEP-66 royalty parameters.
- Wallet logic based on Wallet V5 (W5R1): signed requests and out-action validation.

## How it works

- Public deploy: when the admin enables it, anyone can deploy a wallet and become its owner. The sender of the deploy request pays the deploy price, and the wallet gets the remaining value. An optional referral address gets a share of the deploy price. A public deploy sets no delegate key: the owner sets it after the deploy.
- At a public deploy, the collection draws a random trait set index on-chain. Off-chain metadata can map this index to NFT traits.
- The owner can manage the wallet assets with owner actions.
- The owner can set, change or remove the delegate key (the Ed25519 public key of the delegate).
- The delegate signs requests, which come to the wallet as external or internal messages, with its Ed25519 private key.
- The owner can transfer ownership of the wallet with a TEP-62 NFT transfer. The new owner gets the wallet with all its assets (GRAM, jettons and other NFTs) and its roles in other contracts.

## Security

### Security model

- No one can change the contract code after deployment.
- The admin can not move wallet assets, and can not change the owner or the delegate key of a deployed wallet.
- The delegate can not change the owner or the delegate key.
- An NFT transfer removes the delegate key, even when the new owner is the current owner.
- An NFT transfer or a delegate key change increments the seqno. This cancels all signed requests with an earlier seqno, even if the owner sets the same key again later.
- Owner actions and signed requests can not destroy the wallet.
- To prevent replay, a signed request is valid only for one network, collection, wallet, request type (external or internal), delegate key and seqno, and only until its expiry time.

### Audit

An AI audit of the contracts used AI tools and security research from the sources below. Their authors did not do the audit. The audit found no exploitable issues.

- Trail of Bits: AI security audit skills.
- CertiK: Tolk security research.
- Esprito: TONSEC TSA and TON AI audit skill.
- Positive Security: TON audit checklist.
- elsvv: TON best-practices skill.

## Quick start

Install [Acton](https://ton-blockchain.github.io/acton/) at the version that [Acton.toml](Acton.toml) pins. Then run:

```bash
acton fmt --check
acton build
acton wrapper --all
acton check
acton test
```

## Project layout

| Path | Contents |
|---|---|
| [contracts/](contracts/) | `AgenticCollection.tolk`, `AgenticWallet.tolk` and shared schemas |
| [scripts/](scripts/) | interactive scripts, one per operation |
| [tests/](tests/) | tests in `nft/` and `w5/`; shared helpers in `fixtures.tolk` (deploys) and `utils.tolk`; gas snapshots in each `benchmarks/` folder |
| [wrappers/](wrappers/) | generated wrappers; client helpers in `utils.tolk`; Acton send methods in `send.tolk` |

## Scripts

```bash
# optional: Toncenter API keys and prompt defaults
cp .env.example .env

# delegate key (one time); necessary for wallet-signed-request
printf '\nAGENTIC_DELEGATE_PRIVATE_KEY=0x%s\n' "$(openssl rand -hex 32)" >> .env

# run a script; every send asks for confirmation
acton run <alias> --net {testnet|mainnet} [--tonconnect]
```

Delegate key: the scripts read `AGENTIC_DELEGATE_PRIVATE_KEY` and prefill its public key. Enter `0` for no delegate.

| Alias | Message | Role |
|---|---|---|
| `collection-deploy` | collection StateInit | admin |
| `collection-public-deploy-wallet` | `RelayPublicDeployWallet` | anyone, with public deploys on |
| `collection-deploy-wallet` | `RelayDeployWallet` | admin |
| `collection-edit-wallet-content` | `RelayEditWalletContent` | admin |
| `collection-edit-content` | `EditCollectionContent` | admin |
| `collection-edit-settings` | `EditCollectionSettings` | admin |
| `collection-withdraw-balance` | `WithdrawCollectionBalance` | admin |
| `collection-change-admin` | `ChangeCollectionAdmin` | admin |
| `collection-info` | getters | anyone |
| `wallet-signed-request` | `ExternalSignedRequest`, `InternalSignedRequest` | delegate |
| `wallet-owner-action` | `OwnerActionRequest` | owner |
| `wallet-change-owner` | `ChangeWalletOwner` | owner |
| `wallet-change-delegate` | `ChangeWalletDelegate` | owner |
| `wallet-info` | getters | anyone |

## Testing

### Coverage

The tests are in `tests/nft/` and `tests/w5/`. The minimum coverage score (lines and branches together) is 98.7% (`[test.coverage]` in [Acton.toml](Acton.toml)).

All lines are covered, but some branches are not. These branches reject external messages before the wallet accepts them. A rejected external message makes no transaction, so the coverage tool can not record these branches. The tests check their exit codes instead.

### Mutation score

```bash
acton run mutate-collection
acton run mutate-wallet
```

The tests kill all critical, major and minor mutants in the score. The minimum mutation score is 100% (`[test.mutation]` in [Acton.toml](Acton.toml)).

Two kinds of mutant are not in the score:

- **`|` → `^` on send and reserve mode flags.** [mutation-rules.json](mutation-rules.json) skips them, because these flags never overlap and the mutant compiles to the same code. The tests kill the `|` → `&` mutants on the same lines.
- **Compile errors on `if (x != null)` checks.** The mutant uses a nullable value as non-null, and Tolk rejects it. The tool still mutates the code inside these checks, and the tests kill all those mutants.

### Gas benchmarks

```bash
# update the snapshot files
acton run bench-nft
acton run bench-w5

# fail on any gas change from the snapshots
acton run gas-check-nft
acton run gas-check-w5
```

The snapshots record the gas of each operation.

## License

[MIT](LICENSE)
