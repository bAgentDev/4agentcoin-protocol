# 4AgentCoin protocol and Skill

This public repository contains the 4AgentCoin smart contracts and Agent Skill. Website source code is maintained separately and is not included here.

## Current status

- The project adapter and core contracts are deployed on BSC mainnet (chain 56). The eight deployment/binding receipts, runtime code, owners, proxy implementations and protocol bindings have been checked against the chain. Genesis minting is open; staking and mining remain closed, and the BNB/4AGC liquidity pair has not been created.
- GenesisMiner and MiningPool use UUPS implementations behind ERC1967 proxies. FourAgentCoin remains a fixed contract. The local identity mock is for tests and explicitly local demonstrations only.
- Local build and regression tests are available, with separate opt-in fork checks against the actual BSC Registry and PancakeSwap V2. These checks are not a security audit or proof that every operation has been validated with a live wallet, paid model or funded production pool.
- Installation does not connect a wallet, grant spending authority or open protocol functions. The user still configures their own wallet, miner and explicit work consent.

## Protocol

The three core contracts are:

- `GenesisMiner`: an upgradeable ERC-721 implementation for miners, fixed power assigned in the mint transaction, mint eligibility, stake locks and the embedded BNB marketplace.
- `FourAgentCoin`: the fixed 4AGC token, with a 21,000,000 token cap, initial liquidity allocation and restricted mining issuance.
- `MiningPool`: an upgradeable implementation for noncustodial staking, per-miner tasks, answer verification and immediate reward minting. Holding or staking alone earns no rewards.

`BinanceAgentIdentityAdapter` is the fixed identity reader used by the NFT and Pool. It connects the project interface to the verified official Registry without a project identity server, user-entered identity or administrator allowlist.

Users interact with the NFT and Pool proxy addresses. Each proxy is initialized atomically by a delegatecall from its ERC1967Proxy constructor. The NFT initializer assigns reserved IDs 0–2099 and emits ERC2309 from the proxy address while the proxy is still under construction. Reserved allocation cannot be deferred to a second transaction or repeated during an upgrade. Implementation constructors disable initializers; the public proxy initializer cannot run again after deployment.

Each proxy's Ownable2Step owner directly controls UUPS upgrades and business administration; there is no separate ProxyAdmin. Pool bindings remain the stable proxy addresses, including the Token's existing lock after the first mining issuance. The fixed Token cap does not make the upgradeable Pool's emission logic immutable. This architecture keeps the current business and economic rules, while retaining administrator upgrade authority.

The NFT marketplace settles in BNB. A purchase pays the seller the price minus the 5% market fee directly, with the fee rounded down to whole wei and retained in the contract for administrator withdrawal. No seller withdrawal step is required. Failed seller payment or NFT receipt reverts the entire purchase, including payment, ownership, listing and fee changes; gas is still spent. Primary mint revenue remains separately accounted for under the existing 50/50 LP and operations budgets.

`AgentTaskVerifier` is an internal pure-computation library used by the pool, not a fourth core deployment. It generates and checks a 16-object, four-slot resource-allocation task. The contract verifies the submitted constraints; it cannot prove that an LLM produced the answer or prevent programs from producing valid answers.

Public miner power combines a client-provided random salt with onchain context. Callers can search salts and influence transaction timing, and block producers can influence the context. This is not manipulation-resistant or verifiably fair randomness.

## Official Agent ID

The BSC Registry is `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` (SPACE ID Agent ID, a fixed contract). Its reviewed runtime is 8,756 bytes with keccak256 `0xc4006e6e6ffaaf6996116617392beabe4f5f0a0795841322f91c2ceac34d6ace`.

The [Binance FAQ](https://web3.binance.com/en/dev-docs/products/agentic-wallet/ai-pro#came-from-the-agent-id-campaign) documents the one-per-user, nontransferable and nonrenameable identity. The address itself was traced through the [official Skill's OpenFour integration](https://github.com/binance/binance-skills-hub/blob/main/skills/binance-web3/binance-agentic-wallet/references/agent-id-exclusive-token-launches.md): preset `1778027615735` uses an actual trade module whose identity configuration returns this Registry, then checks its `balanceOf`. The [Sourcify record](https://sourcify.dev/server/v2/contract/56/0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F?fields=all) has exact creation/runtime matches for `src/HandleRegistry.sol:HandleRegistry` (Solidity 0.8.24), and its runtime was compared with the deployed bytes. The FAQ alone does not publish the address; the reviewed manifest records the binding evidence and block hashes.

`handleOf(address)` returns the bare handle, without `.ai`. The official NFT tokenId is `uint256(keccak256(bytes(handle)))`; `ownerOfHandle(handle)` and `ownerOf(tokenId)` resolve to the same holder. The adapter returns this tokenId as bytes32 through `agentIdOf(address)`, uses the same official identity for `isEligible(address)`, and exposes `registry()` to verify the fixed binding. Registry failures, missing code or inconsistent identity data stop eligibility-dependent operations; they must not be reported as an unregistered wallet.

The verified Registry permits one handle per address. Existing identities cannot be transferred, burned, renamed, rebound or revoked. Official administrators can change bounds for new names, so the adapter does not revalidate existing IDs against the FAQ's name-length range or current registration bounds. An address hash, user-supplied name, local mock or handle with an added `.ai` suffix is not the official tokenId. Identity-source verification does not authorize a wallet session or prove use of an LLM.

All six deployed instances have matching creation and runtime code on Sourcify (`exact_match`), including both initialized proxies. The manifest records the verification URLs and block hashes. This is source matching, not a security audit.

## Install the Skill

Install Node.js 22.20 or later, npm and Git, then run:

```sh
npx skills add bAgentDev/4agentcoin-protocol --skill 4agentcoin -g
```

Follow the prompts to select your Agent. This installs the same Skill for all supported operations; it does not add separate mint, market or swap CLI commands.

Read [the Skill](skills/4agentcoin/SKILL.md) and its [operation reference](skills/4agentcoin/references/operations.md). Before first using the included runner, enter the installed `4agentcoin` Skill directory and install its locked runtime dependency with `npm ci --ignore-scripts`, as described there. Dependency installation does not call a wallet or broadcast a transaction.

The runner supports `status`, `dry-run` and `run` for one already-staked NFT, using an explicitly authorized Codex CLI model setup. Other wallet operations follow the Skill instructions and the official Binance Agentic Wallet. The packaged example includes reviewed mainnet deployment and identity parameters. The user must still configure their own wallet, actual staked miner and explicit work consent; model automation remains unauthorized and the gas budget is zero until that consent is supplied. The example miner ID is a placeholder, not an asset assigned to the installer.

## Build and test contracts

From the repository root, use Foundry v1.5.1 and npm. Solidity 0.8.34 and compiler settings are recorded in `contracts/foundry.toml`.

```sh
npm ci --ignore-scripts --prefix contracts
forge install --root "$PWD/contracts" foundry-rs/forge-std@rev=7117c90c8cf6c68e5acce4f09a6b24715cea4de6 --no-git
forge build --root "$PWD/contracts"
forge test --root "$PWD/contracts"
```

The default contract regression suite includes proxy initialization, upgrade permissions, preserved state, NFT and mining behavior, and the fixed Token cap. These commands require no wallet, RPC, private key or deployment transaction. Installed dependencies and generated artifacts are ignored by Git. Upgrade safety and storage compatibility require the additional reference-based validation below.

Deployment and local demonstration scripts are included under `contracts/script/`. Building a script does not execute or broadcast it. Production scripts keep protocol gates closed and require independently verified identity and metadata inputs; their presence does not mean production prerequisites are complete.

## BSC deployment

An ordinary EOA can deploy and administer the contracts. The deployer, revenue recipient and LP treasury do not need an Agent ID. Agent identity is required only for public minting, new staking and work submissions. Keep signing keys and passwords in a user-controlled local signer; these scripts never read them.

The public [BSC manifest](config/deployments.bsc.json) records this deployment and enables read-only checking. Actual creation receipts, runtime hashes, proxy implementations, binding checks and per-contract source-verification results are recorded there. Source matching is not a security audit. The administrator, reserve recipient, fee recipient and initial LP treasury are `0x4a395c91484544cec82424cc23af20239feea2d4`.

| Contract | BSC address |
|---|---|
| Genesis NFT proxy | [0xaad237c08b4c44ea8fd4eea02bfc827e94459948](https://bscscan.com/address/0xaad237c08b4c44ea8fd4eea02bfc827e94459948) |
| Genesis implementation | [0xc6af5ebf9354259c99dfb3601f29ea433c77456e](https://bscscan.com/address/0xc6af5ebf9354259c99dfb3601f29ea433c77456e) |
| Fixed 4AGC Token | [0x1cfe1db3d89e6a995862baf6e6687cf0c7ee66f4](https://bscscan.com/address/0x1cfe1db3d89e6a995862baf6e6687cf0c7ee66f4) |
| MiningPool proxy | [0xa12a9112361bab1411e64891da7481deaf9cff59](https://bscscan.com/address/0xa12a9112361bab1411e64891da7481deaf9cff59) |
| MiningPool implementation | [0x84c4c0293c01c0abeb52992c478ead352fcc67fe](https://bscscan.com/address/0x84c4c0293c01c0abeb52992c478ead352fcc67fe) |
| Fixed Agent ID adapter | [0xf9c3e5de50da00c9b35670b4418205b1a0527dbf](https://bscscan.com/address/0xf9c3e5de50da00c9b35670b4418205b1a0527dbf) |

Use the NFT and Pool proxy addresses for business operations. Deployment created 2,100 reserved miners at 150 HP and the 1,050,000-token initial LP allocation; public minting and mining issuance were both zero at the deployment check. LP creation, funding and transaction deadlines require separate review.

The eight mainnet transactions completed in BSC blocks 131063845–131063883: the real `BinanceAgentIdentityAdapter`, two implementations, two atomically initialized proxies, the fixed Token and two Pool bindings. They used 8,761,083 gas at 0.05 gwei, for an actual total network fee of **0.00043805415 BNB**; every transaction's value was zero. LP principal, LP initialization and later manual operations are outside this cost. The recorded 0.00065759215 BNB preflight was a simulation with a 150% gas estimate multiplier, not the actual charge.

The deployment script verifies the official Registry runtime and identity configuration pointer before creating the adapter. The eight creation and binding transactions initialized all gates closed. The administrator subsequently opened only Genesis minting with [`setMintOpen(true)`](https://bscscan.com/tx/0xdbca610d9f10ef408674ae479ae060e5e16758cffe193d48dc713ecacef57fc2) in block 131168908 on November 2, 2026. Its value was zero and its actual network fee was 0.0000019359 BNB. Staking, mining and LP activation remain separate manual operations. Do not rerun the creation script to manage the deployed contracts; use the reviewed proxy addresses and the appropriate operation.

From `contracts/`, after independently verifying the actual deployment and reviewing the manifest, the read-only check is:

```sh
forge script script/VerifyDeployment.s.sol:VerifyDeployment --rpc-url "$BSC_RPC_URL"
```

The committed mainnet manifest enables deployment verification; this setting does not open the protocol gates. The checker never broadcasts. It checks proxy code, the ERC1967 implementation slot, reviewed implementation code hashes and business bindings; unchanged proxy code alone is insufficient. `expected.requirePair=false` explicitly leaves LP acceptance incomplete; after funding, record the real Pair address/hash and a positive reviewed LP minimum before requiring Pair verification. Update the expected treasury exemption if it is removed.

`BootstrapLiquidity.s.sol` supports one manually selected action per invocation: `withdrawLP`, `withdrawOperations`, `createPair`, `registerPair`, `approve`, `addLiquidity`, `revokeApproval`, or `removeTreasuryExemption`. For example, the following is a simulation only:

```sh
SIGNER_ADDRESS="$DEPLOYER_ADDRESS" BOOTSTRAP_ACTION=createPair \
  forge script script/BootstrapLiquidity.s.sol:BootstrapLiquidity --rpc-url "$BSC_RPC_URL"
```

The administrator performs revenue withdrawals, Pair registration and exemption changes; the LP treasury performs its own approval and funding. Roles may use different addresses. The 50/50 sale budgets are actual collected revenue, not prepaid BNB. Review explicit amounts, minima, deadline and LP share recipient. Record and verify a newly created Pair before the next step. Approval is exact, and the Pair must not be tax-exempt. Every action preserves the business gates. No example here broadcasts; any later broadcast needs a separately reviewed transaction and the user's local signer. Script postconditions run in Foundry simulation. Empty-Pair and minimum-LP-share checks are not encoded as additional guards in the Router call; the Router enforces its amount minima and deadline. After a real transaction, independently check the receipt, balances, reserves, LP shares and remaining allowance through the RPC and read-only verifier.

Real Registry and PancakeSwap V2 fork tests are separate from the default contract suite and ordinary CI:

```sh
BSC_RPC_URL="https://your-reviewed-bsc-rpc" BSC_FORK_BLOCK_NUMBER="your-reviewed-block" \
  FOUNDRY_PROFILE=bsc_fork forge test --match-contract PancakeV2ForkTest -vv

BSC_RPC_URL="https://your-reviewed-bsc-rpc" BSC_FORK_BLOCK_NUMBER="your-reviewed-block" \
  FOUNDRY_PROFILE=bsc_fork forge test --match-path 'fork/AgentIdentityFork.t.sol' -vv
```

Set a reachable BSC mainnet RPC and an explicit block with available historical state. The tests check source chain 56, record the source block/hash, and perform transactions only inside the local EVM on chain 31337 with synthetic balances. The identity fork checks real Registry reads and adapter integration; its locally simulated minting and work do not create production assets. Missing RPC/block or unavailable state is an uncompleted fork check, not a pass. Fork success does not establish actual project deployment or authorize production transactions. No paid service is required by these files.

The current local fork passed 7 real-Registry integration tests and 8 V2 tests at BSC source block `131061945` (`0xce92d1b6f39d0857c55699e11e3f69508abd02c359090fdaa558761eabfd6807`), with all protocol mutations kept in the local EVM. A separate local Anvil run at source block `131037002` measured Token deployment, Pair creation, registration, exact approval and LP funding: 4,671,386 gas used across five local transactions, of which 3,599,276 is the four AMM steps excluding the duplicate Token deployment. The manifest keeps the per-transaction estimates and receipts as local references. No production BNB was spent by those local fork runs. Their V2 measurements remain separate from the actual eight-transaction mainnet deployment recorded above. `budget.estimateVerified` refers to the preflight estimate; actual receipts and fees are in the manifest's `deployment` record. Neither the fork runs nor the deployment established or funded an LP.

## Review and simulate an upgrade

Close mint, staking and mining manually before preparing an upgrade. Preserve the actual deployed version's original build-info directory, compiler settings and locked dependencies as the reference. OpenZeppelin 5.6.1 base storage uses ERC7201 namespaces; application storage must retain its established order and types, with only compatible additions. Do not rerun the original initializer or treat a fresh build of the new source as the old deployed reference.

From `contracts/`, independently run the pinned upgrades-core 1.46.0 CLI with the actual target contract, reference contract and retained build-info directory:

```sh
mkdir -p broadcast
./node_modules/.bin/openzeppelin-upgrades-core validate out/build-info \
  --contract "$TARGET_CONTRACT" --reference "$REFERENCE_CONTRACT" \
  --referenceBuildInfoDirs "$REFERENCE_BUILD_INFO_DIR" \
  --requireReference --unsafeAllow constructor \
  > ./broadcast/upgrade-storage-validation-cli.txt 2>&1
```

For a reference in another build-info directory, prefix its contract name with that directory's short name. Check the command's successful exit status and review its full output. Never use `unsafeSkipStorageCheck` or broaden initializer/storage exceptions. The limited `--unsafeAllow constructor` accommodates the fixed OpenZeppelin 5.6.1 ReentrancyGuard constructor. CI also pins that vendor file's SHA and checks every linearized constructor of the upgradeable implementations, allowing only the fixed vendor constructor and each implementation's `_disableInitializers()`. This does not authorize new application constructor logic.

`UpgradeProtocol.s.sol` consumes an operator-reviewed attestation; it does not run that CLI or generate independent compatibility proof. After independently validating and reviewing the exact sources and deployed implementation hashes, record the attestation under the existing `contracts/broadcast/` path, using the manifest's `upgrade.storageValidationReportPath` (default `./broadcast/upgrade-storage-validation.json` from `contracts/`). Required report fields include `tool=openzeppelin-upgrades-core`, `toolVersion=1.46.0`, `referenceContract`, `targetContract`, `referenceImplementationCodeHash`, `newImplementationCodeHash`, `storageCompatible`, and `unsafeSkipStorageCheck=false`. Retain the command, output and review record with it. Set `upgrade.storageValidationReportHash` to the keccak256 of the report's exact bytes only after review. A matching report hash locks those inputs; it cannot prove that the operator executed the tool or that every business state is compatible.

The reviewed manifest selects exactly `upgrade.target=genesis` or `pool`, the new implementation address/hash and any reviewed migration calldata. Token is not an upgrade target. The mainnet deployment record is enabled for reading; `upgrade.enabled` remains false by default. Once all prerequisites are independently verified, this command simulates one selected proxy upgrade without broadcasting:

```sh
SIGNER_ADDRESS="$ADMIN_ADDRESS" \
  forge script script/UpgradeProtocol.s.sol:UpgradeProtocol --rpc-url "$BSC_RPC_URL"
```

The script checks the owner, old and new implementation hashes, ERC1967 UUID, stable bindings and closed gates, then samples core state after the simulated upgrade. These checks do not replace layout validation or state-preservation regressions. Any actual broadcast needs separate user authorization and a local signer. Afterwards, verify the real receipt and implementation slot before updating the reviewed manifest, website and Skill implementation metadata. Reopening gates is a separate manual action.

The Skill and website verify proxy and implementation metadata before new operations. The runner rechecks before the model, preview and execute; an unknown implementation stops it even when the task nonce is unchanged. Its authorization fingerprint binds the reviewed implementations, so a changed implementation requires new explicit work consent. Read-only status/history still exposes original and replacement receipts when current deployment verification fails. Pre-submission checks cannot prevent an owner from upgrading while a transaction is pending.

## Test the Skill

From the repository root:

```sh
npm ci --ignore-scripts --prefix skills/4agentcoin
npm test --prefix skills/4agentcoin
```

The Skill regression suite covers strict user-confirmation values, actual transaction hashes and gas after repricing or cancellation, restart holds, implementation changes before model/preview/execute, and read-only history when deployment or proxy checks fail. Its injected tests do not spend model credits, sign transactions or broadcast to a network. See the Skill reference for actual runner configuration and its authorization, budget and pending-transaction rules.

## License

The [MIT license](LICENSE) applies to the contents of this repository. It does not grant rights to separately maintained website code, artwork or other repositories. Third-party dependencies retain their own licenses.
