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

## Test the Skill

From the repository root:

```sh
npm ci --ignore-scripts --prefix skills/4agentcoin
npm test --prefix skills/4agentcoin
```

The current Skill regression suite has 28 tests. It covers strict user-confirmation values, actual transaction hashes and gas after repricing or cancellation, restart holds, and read-only history when current deployment checks fail. Its injected tests do not spend model credits, sign transactions or broadcast to a network. See the Skill reference for actual runner configuration and its authorization, budget and pending-transaction rules.

## License

The [MIT license](LICENSE) applies to the contents of this repository. It does not grant rights to separately maintained website code, artwork or other repositories. Third-party dependencies retain their own licenses.
