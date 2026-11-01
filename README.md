# 4AgentCoin protocol and Skill

This public repository contains the 4AgentCoin smart contracts and Agent Skill. Website source code is maintained separately and is not included here.

## Current status

- These contracts have not been deployed to mainnet. A verified production adapter for the official Agent identity registry is not yet implemented.
- The contracts use constructors and are not upgradeable proxies. The local identity mock is for tests and explicitly local demonstrations only.
- Local build and regression tests are available. They are not a security audit or proof that every operation has been validated with a live wallet, paid model, production identity registry or trading pool.
- Installation does not connect a wallet, grant spending authority, configure a production deployment or open protocol functions.

## Protocol

The three core contracts are:

- `GenesisMiner`: ERC-721 miners, fixed power assigned in the mint transaction, mint eligibility, stake locks and the embedded BNB marketplace.
- `FourAgentCoin`: the 4AGC token, with a 21,000,000 token cap, initial liquidity allocation and restricted mining issuance.
- `MiningPool`: noncustodial staking, per-miner tasks, answer verification and immediate reward minting. Holding or staking alone earns no rewards.

The NFT marketplace settles in BNB. A purchase pays the seller the price minus the 5% market fee directly, with the fee rounded down to whole wei and retained in the contract for administrator withdrawal. No seller withdrawal step is required. Failed seller payment or NFT receipt reverts the entire purchase, including payment, ownership, listing and fee changes; gas is still spent. Primary mint revenue remains separately accounted for under the existing 50/50 LP and operations budgets.

`AgentTaskVerifier` is an internal pure-computation library used by the pool, not a fourth core deployment. It generates and checks a 16-object, four-slot resource-allocation task. The contract verifies the submitted constraints; it cannot prove that an LLM produced the answer or prevent programs from producing valid answers.

Public miner power combines a client-provided random salt with onchain context. Callers can search salts and influence transaction timing, and block producers can influence the context. This is not manipulation-resistant or verifiably fair randomness.

## Install the Skill

Install Node.js 22.20 or later, npm and Git, then run:

```sh
npx skills add bAgentDev/4agentcoin-protocol --skill 4agentcoin -g
```

Follow the prompts to select your Agent. This installs the same Skill for all supported operations; it does not add separate mint, market or swap CLI commands.

Read [the Skill](skills/4agentcoin/SKILL.md) and its [operation reference](skills/4agentcoin/references/operations.md). Before first using the included runner, enter the installed `4agentcoin` Skill directory and install its locked runtime dependency with `npm ci --ignore-scripts`, as described there. Dependency installation does not call a wallet or broadcast a transaction.

The runner supports `status`, `dry-run` and `run` for one already-staked NFT, using an explicitly authorized Codex CLI model setup. Other wallet operations follow the Skill instructions and the official Binance Agentic Wallet. A verified deployment, official identity evidence where required, configuration and user authorization are still necessary. The included example is deliberately unconfigured and disabled.

## Build and test contracts

From the repository root, use Foundry v1.5.1 and npm. Solidity 0.8.34 and compiler settings are recorded in `contracts/foundry.toml`.

```sh
npm ci --ignore-scripts --prefix contracts
forge install --root "$PWD/contracts" foundry-rs/forge-std@rev=7117c90c8cf6c68e5acce4f09a6b24715cea4de6 --no-git
forge build --root "$PWD/contracts"
forge test --root "$PWD/contracts"
```

The current contract regression suite has 54 tests. These commands require no wallet, RPC, private key or deployment transaction. Installed dependencies and generated artifacts are ignored by Git.

Deployment and local demonstration scripts are included under `contracts/script/`. Building a script does not execute or broadcast it. Production scripts keep protocol gates closed and require independently verified identity and metadata inputs; their presence does not mean production prerequisites are complete.

## BSC deployment preparation

An ordinary EOA can deploy and administer the contracts. The deployer, revenue recipient and LP treasury do not need an Agent ID. Agent identity is required only for public minting, new staking and work submissions. Keep signing keys and passwords in a user-controlled local signer; these scripts never read them.

The public [BSC manifest](config/deployments.bsc.json) is disabled. Core deployment and identity addresses, transaction amounts and deadlines are intentionally unset. Its reviewed PancakeSwap addresses and code hashes do not establish project liquidity or official identity readiness. The current contracts remain constructor-based and non-upgradeable.

From `contracts/`, after independently verifying the actual deployment and reviewing the manifest, the read-only check is:

```sh
forge script script/VerifyDeployment.s.sol:VerifyDeployment --rpc-url "$BSC_RPC_URL"
```

The default manifest must stop with `BLOCKED: deployment manifest is disabled`. The checker never broadcasts. `expected.requirePair=false` explicitly leaves LP acceptance incomplete; after funding, record the real Pair address/hash and a positive reviewed LP minimum before requiring Pair verification. Update the expected treasury exemption if it is removed.

`BootstrapLiquidity.s.sol` supports one manually selected action per invocation: `withdrawLP`, `withdrawOperations`, `createPair`, `registerPair`, `approve`, `addLiquidity`, `revokeApproval`, or `removeTreasuryExemption`. For example, the following is a simulation only:

```sh
SIGNER_ADDRESS="$DEPLOYER_ADDRESS" BOOTSTRAP_ACTION=createPair \
  forge script script/BootstrapLiquidity.s.sol:BootstrapLiquidity --rpc-url "$BSC_RPC_URL"
```

The administrator performs revenue withdrawals, Pair registration and exemption changes; the LP treasury performs its own approval and funding. Roles may use different addresses. The 50/50 sale budgets are actual collected revenue, not prepaid BNB. Review explicit amounts, minima, deadline and LP share recipient. Record and verify a newly created Pair before the next step. Approval is exact, and the Pair must not be tax-exempt. Every action preserves the business gates. No example here broadcasts; any later broadcast needs a separately reviewed transaction and the user's local signer. Script postconditions run in Foundry simulation. Empty-Pair and minimum-LP-share checks are not encoded as additional guards in the Router call; the Router enforces its amount minima and deadline. After a real transaction, independently check the receipt, balances, reserves, LP shares and remaining allowance through the RPC and read-only verifier.

Real PancakeSwap V2 fork tests are separate from the default 54-test suite and ordinary CI:

```sh
BSC_RPC_URL="https://your-reviewed-bsc-rpc" BSC_FORK_BLOCK_NUMBER="your-reviewed-block" \
  FOUNDRY_PROFILE=bsc_fork forge test --match-contract PancakeV2ForkTest -vv
```

Set a reachable BSC mainnet RPC and an explicit block with available historical state. The test checks source chain 56, records the source block/hash, and performs transactions only inside the local EVM on chain 31337 with synthetic balances. Missing RPC/block or unavailable state is an uncompleted fork check, not a pass. Fork success does not authenticate the project's pending Agent ID adapter or authorize production transactions. No paid service is required by these files.

The recorded local V2 fork passed 8 tests at source block `131036262`. A separate local Anvil run at source block `131037002` measured Token deployment, Pair creation, registration, exact approval and LP funding: 4,671,386 gas used across five local transactions, of which 3,599,276 is the four AMM steps excluding the duplicate Token deployment. The manifest keeps the per-transaction estimates and receipts as local references. No production BNB was spent; the production identity adapter and other unmeasured operations remain outside this reference, so `budget.estimateVerified` stays false.

## Test the Skill

From the repository root:

```sh
npm ci --ignore-scripts --prefix skills/4agentcoin
npm test --prefix skills/4agentcoin
```

The current Skill regression suite has 28 tests. It covers strict user-confirmation values, actual transaction hashes and gas after repricing or cancellation, restart holds, and read-only history when current deployment checks fail. Its injected tests do not spend model credits, sign transactions or broadcast to a network. See the Skill reference for actual runner configuration and its authorization, budget and pending-transaction rules.

## License

The [MIT license](LICENSE) applies to the contents of this repository. It does not grant rights to separately maintained website code, artwork or other repositories. Third-party dependencies retain their own licenses.
