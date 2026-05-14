# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

stOLAS is an ERC4626 liquid staking vault for OLAS tokens. Users deposit OLAS on L1 (Ethereum) and receive stOLAS tokens. The deposited OLAS is bridged to L2 chains (Gnosis, Base, Mode) for active staking in the Autonolas service ecosystem. Rewards flow back from L2 to L1, increasing the stOLAS price-per-share.

## Build & Test Commands

```bash
make install          # Install all dependencies (poetry, forge, yarn)
make build            # forge build
make fmt              # forge fmt && forge fmt --check
make lint             # solhint on contracts/**/*.sol
make tests            # forge test -vvv
make tests-hardhat    # Hardhat JS tests (temporarily renames LzOracle.sol)
make tests-coverage   # forge coverage -vvvv

# Run a single Forge test file
forge test --match-path "test/LiquidStaking.t.sol" -vv

# Run a single Forge test function
forge test --match-test "testDepositAndStake" -vvv

# Hardhat test variants
npm run test:hardhat   # Full JS test suite
npm run test:fast      # Optimized subset
npm run test:original  # Original comprehensive suite
```

**Note:** Hardhat tests temporarily rename `LzOracle.sol` to avoid compilation conflicts. The npm scripts handle this automatically.

## Solidity Configuration

- **Compiler:** 0.8.30, optimizer enabled (1M runs), viaIR, EVM target: Prague
- **Source directory:** `contracts/`
- **Key remappings** (in `foundry.toml`): `@openzeppelin`, `@solmate`, `@registries`, `@layerzerolabs`, `@gnosis.pm`

## Architecture

### L1 Contracts (`contracts/l1/`)

| Contract | Role |
|---|---|
| **stOLAS** | ERC4626 vault. Tracks `stakedBalance`, `vaultBalance`, `reserveBalance`. PPS = totalReserves / totalSupply |
| **Depository** | Routes deposits to L2 staking models. Manages model lifecycle (Active/Inactive/Retired) and product types (Alpha/Beta/Final) |
| **Treasury** | Withdrawal requests via ERC6909 tokens. Triggers L2 unstaking if vault liquidity is insufficient |
| **Distributor** | Receives bridged rewards. Splits between veOLAS lock and stOLAS vault top-up |
| **Lock** | veOLAS management for governance voting power |
| **UnstakeRelayer** | Receives OLAS from retired L2 staking models, returns to stOLAS reserve |

### L2 Contracts (`contracts/l2/`)

| Contract | Role |
|---|---|
| **StakingManager** | Orchestrates service deployment/staking. Creates ActivityModule BeaconProxy instances per service |
| **ExternalStakingDistributor** | Manages external staking on third-party staking proxies. Deploys services (creates Safe multisigs with self as module), stakes/unstakes/re-stakes them, claims and distributes rewards (split between Collector, protocol, and curating agent per configurable factors). Supports V1 (rewards on multisig) and V2 (rewards on contract) staking types. Access-controlled via owner, whitelisted managing agents (for unstakes), and per-proxy curating agents guarded by staking guards. Receives OLAS deposits from L2 staking processor and handles withdraw/unstake requests back through Collector |
| **StakingTokenLocked** | Restricted StakingToken that only allows StakingManager as staker |
| **ActivityModule** | Per-service BeaconProxy. Verifies liveness, shields staking funds, triggers reward claims |
| **Collector** | Collects L2 rewards and bridges to L1 (REWARD→Distributor, UNSTAKE→Treasury, UNSTAKE_RETIRED→UnstakeRelayer) |

### Bridging (`contracts/l1/bridging/`, `contracts/l2/bridging/`)

- LayerZero V2 for cross-chain messaging
- Chain-specific processors: `GnosisDepositProcessorL1`/`L2`, `BaseDepositProcessorL1`/`L2`, `DefaultDepositProcessorL1`/`L2`
- `LzOracle` for LayerZero-driven staking model management

### Core Patterns

- **Proxy architecture:** UUPS-style via `Implementation.sol` (owner management + upgrade logic) and `Beacon.sol` (BeaconProxy for ActivityModules)
- **ERC standards:** ERC4626 (vault), ERC6909 (withdrawal tickets), ERC721 (service NFTs from Autonolas registry)
- **Libraries:** Solmate (ERC4626, ERC6909, ERC721), OpenZeppelin (security utilities), Autonolas Registries (staking infra)

### Cross-Chain Flow

```
Stake:   Depository (L1) → DepositProcessor → Bridge → StakingProcessorL2 → StakingManager (L2)
Rewards: Collector (L2) → Bridge → Distributor (L1) → stOLAS
Unstake: Collector (L2) → Bridge → Treasury/UnstakeRelayer (L1) → stOLAS
```

## Deployment

- Scripts in `scripts/deployment/` follow numbered sequences: `deploy_l1_01_*` through `deploy_l1_15_*`, `deploy_l2_01_*` through `deploy_l2_09_*`
- Configuration scripts: `script_l1_*`, `script_l2_*` for post-deployment setup
- Contract addresses: `doc/configuration.json`
- Finalized ABIs: `abis/0.8.30/`
- Static audit: `./scripts/deployment/script_static_audit.sh eth_mainnet NETWORK_mainnet`

## ERC4626 Caveat

`deposit` is meant to be called only via **Depository**, and `redeem` only via **Treasury**. The `mint`/`withdraw` functions are non-standard and not for external use.

## Audit Findings & Resolutions

The project has undergone 9 internal audits (`audits/audit1` through `audits/audit9`) and 1 external audit (CODESPECT).

### audit8 (2026-03-08) — all informational, all fixed
- **INFO-1**: Treasury `requestToWithdraw` didn't forward `msg.value` to unstake calls → Fixed: validates and forwards ETH correctly
- **INFO-2**: Distributor `_increaseLock` left dangling OLAS approval on failure → Fixed: resets approval to 0
- **INFO-3**: ERC6909 withdrawal tokens are transferable → By design
- **INFO-4**: Permissionless trigger functions → By design

### audit9 (2026-03-18) — 5 Low, 5 Informational, all resolved
- **L-1**: `reStake` used dead `mapCuratingAgents` mapping → Fixed: uses `mapServiceIdCuratingAgents[serviceId]`
- **L-2**: `stOLAS.initialize()` no access control → By design (atomic deployment)
- **L-3**: `DefaultDepositProcessorL1.drain()` sends ETH to `address(0)` → Fixed: removed `drain()` entirely (ETH cannot get stuck)
- **L-4**: Distributor dangling approval → Fixed (same as audit8 INFO-2)
- **L-5**: `StakingTokenLocked.maxNumInactivityPeriods` unused → By design (backward compatibility)
- **INFO-1**: `setCuratingAgents` `stakingHash` in loop → Fixed: moved before loop
- **INFO-2**: `unstakeAndWithdraw` missing entry validation → Fixed: added zero-checks at entry
- **INFO-3**: `claim()` permissionless → By design
- **INFO-4**: `unstakeRetired()` permissionless → By design
- **INFO-5**: `LzOracle._lzReceive` trusts LZ Read → By design

## Modified Contracts (not yet re-deployed)

Contracts that have been modified but not yet re-deployed are tracked in
[`MODIFIED_CONTRACTS.md`](MODIFIED_CONTRACTS.md). Keep that file in sync when changing a
deployed contract, and clear entries once re-deployed.
