# Security Audit Report — olas-lst (stOLAS)

**Date**: 2026-03-08
**Scope**: All contracts in `contracts/` (excluding `lib/`, `test/`, `contracts/l1/concept/`, `contracts/test/`)
**Lines of Code**: 8,086 LOC across 29 contracts

---

## Executive Summary

The stOLAS liquid staking protocol was audited following the 5-phase security audit methodology. The codebase implements a cross-chain ERC4626 vault system with L1 (Ethereum) deposits/withdrawals and L2 (Gnosis/Base) staking operations.

**Result: No bounty-qualifying vulnerabilities found.**

The protocol demonstrates mature defensive coding patterns:
- Internal accounting model (totalReserves) immune to donation-based price manipulation
- Time-delayed withdrawals preventing flash loan and sandwich attacks
- Per-contract reentrancy guards (transient storage on L1, persistent on L2)
- Strict access control with one-caller-per-function pattern on stOLAS
- Optimistic cross-chain accounting with recovery mechanisms for failed bridge messages

4 informational observations were documented. The protocol has undergone 7 internal and 1 external audit (CODESPECT), and the code quality reflects this maturity.

---

## Scope

### In-Scope Contracts

**L1 (Ethereum) — 2,633 LOC**
| Contract | LOC | Description |
|----------|-----|-------------|
| stOLAS.sol | 378 | ERC4626 vault, main entry point |
| Depository.sol | 1,139 | Staking model management, cross-chain bridge hub |
| Treasury.sol | 303 | Withdrawal queue, ERC6909 claim tokens |
| Distributor.sol | 148 | Reward split (veOLAS lock + vault) |
| Lock.sol | 287 | veOLAS lock management, governance proxy |
| UnstakeRelayer.sol | 80 | Retired model unstake relay |

**L1 Bridging — 738 LOC**
| Contract | LOC | Description |
|----------|-----|-------------|
| DefaultDepositProcessorL1.sol | 182 | Abstract bridge base |
| BaseDepositProcessorL1.sol | 116 | Optimism/Base bridge |
| GnosisDepositProcessorL1.sol | 62 | Gnosis AMB bridge |
| LzOracle.sol | 378 | LayerZero lzRead oracle (NOT currently used) |

**L2 (Gnosis/Base) — 3,851 LOC**
| Contract | LOC | Description |
|----------|-----|-------------|
| StakingManager.sol | 556 | Service orchestration |
| ExternalStakingDistributor.sol | 1,123 | External staking management |
| StakingTokenLocked.sol | 848 | Locked staking instance |
| ActivityModule.sol | 342 | Service activity + claim |
| Collector.sol | 406 | Reward collection + bridging |
| StakingHelper.sol | 77 | View helper |
| MultisigGuard.sol | 216 | Safe guard for externals |
| ModuleActivityChecker.sol | 33 | Activity nonce checker |

**L2 Bridging — 679 LOC**
| Contract | LOC | Description |
|----------|-----|-------------|
| DefaultStakingProcessorL2.sol | 473 | Abstract bridge base |
| BaseStakingProcessorL2.sol | 113 | Optimism/Base bridge |
| GnosisStakingProcessorL2.sol | 93 | Gnosis bridge |

**Infrastructure — 255 LOC**
| Contract | LOC | Description |
|----------|-----|-------------|
| Beacon.sol | 62 | Beacon pattern |
| BeaconProxy.sol | 60 | EIP-1967 beacon proxy |
| Proxy.sol | 73 | UUPS-style proxy |
| Implementation.sol | 60 | Base implementation with owner |

### Out of Scope
- `lib/` dependencies (autonolas-registries, LayerZero, OpenZeppelin, solmate)
- `contracts/test/` mock contracts
- `contracts/l1/concept/` experimental contracts
- Owner/multisig actions (trusted role per CLAUDE.md)
- LzOracle.sol (confirmed not currently used)

---

## Findings

### Critical: 0
### High: 0
### Medium: 0
### Low: 0

### Informational: 4

#### INFO-1: Missing ETH Forwarding in Treasury.requestToWithdraw
| | |
|---|---|
| **Location** | Treasury.sol:220-221, 227-228 |
| **Description** | `requestToWithdraw` is `payable` but doesn't forward `msg.value` to `Depository.unstake`/`unstakeExternal` calls |
| **Impact** | None currently — Optimism and Gnosis bridges don't require ETH for L1→L2 messages. If a bridge requiring ETH is added, unstaking from Treasury would fail. |
| **Recommendation** | Add `{value: ...}` forwarding or document that future bridges must not require ETH for L1→L2 UNSTAKE messages |

#### INFO-2: Dangling OLAS Approval in Distributor
| | |
|---|---|
| **Location** | Distributor.sol:75 |
| **Description** | If `Lock.increaseLock()` fails via low-level call, OLAS approval to Lock remains until next `distribute()` call |
| **Impact** | None — Lock is immutable trusted address. Approval overwritten on next distribute(). |
| **Recommendation** | Consider resetting approval to 0 after failed lock call |

#### INFO-3: ERC6909 Withdrawal Tokens Are Transferable
| | |
|---|---|
| **Location** | Treasury.sol:190, solmate ERC6909 |
| **Description** | Withdrawal claim tokens can be transferred. New holder can finalize withdrawal after delay. |
| **Impact** | Feature, not bug. Enables secondary market for withdrawal claims. |
| **Recommendation** | Document this behavior for users |

#### INFO-4: Multiple Permissionless Trigger Functions
| | |
|---|---|
| **Location** | Depository.sol:763,829; Distributor.sol:125; UnstakeRelayer.sol:60; Collector.sol:317; ActivityModule.sol:303 |
| **Description** | These functions (unstakeRetired, closeRetiredStakingModels, distribute, relay, relayTokens, claim) can be called by anyone. |
| **Impact** | None — all are designed as permissionless triggers. Cannot cause fund loss when called by untrusted parties. |
| **Recommendation** | N/A — by design |

---

## Methodology

### Phase 1: Architecture Map
- Mapped 29 in-scope contracts across L1, L2, bridging, and infrastructure layers
- Documented inheritance hierarchy, inter-contract call graph, access control matrix
- Identified 10 priority attack surface areas

### Phase 2: Invariant Identification
- Verified 10 core invariants (all holding)
- Disproved 8 initial candidate findings through code verification
- Identified 8 candidates for Phase 3 deep investigation

### Phase 3: Attack Discovery
- Investigated all 8 Phase 2 candidates — all disproved
- Ran 16-item EVM checklist — all SAFE
- Ran 8-item DeFi attack pattern checklist — all SAFE
- Applied disprove-first methodology to every finding

### Coverage

| Category | Items Checked |
|----------|--------------|
| Phase 2 candidates | 8/8 investigated |
| EVM patterns | 16/16 checked |
| DeFi patterns | 8/8 checked |
| Invariants verified | 10/10 |
| False positives disproved | 17 |
| Informational findings | 4 |

---

## Key Architectural Observations

### Strengths
1. **Internal accounting model**: `totalAssets()` returns `totalReserves` (not `balanceOf`), making the vault immune to donation-based attacks (ERC4626 inflation, share price manipulation)
2. **Withdrawal delay**: Time-delayed withdrawals via Treasury prevent flash loans, sandwich attacks, and cross-chain arbitrage
3. **Access control isolation**: Each stOLAS function has exactly one authorized caller — no cross-role attack vectors
4. **Graceful degradation**: Distributor handles Lock failure gracefully (all rewards go to vault); L2 bridge queues failed operations for retry
5. **Rounding direction**: Both deposit and redeem use `mulDivDown` (favor vault), preventing rounding extraction

### Design Trade-offs (Not Vulnerabilities)
1. **Optimistic cross-chain accounting**: L1 updates balances before L2 confirms. Relies on operational liveness for recovery.
2. **No virtual shares**: stOLAS doesn't implement OpenZeppelin's virtual shares offset. Mitigated by depository-only deposit access control.
3. **ERC4626 non-standard functions**: `mint()` and `withdraw()` revert. May confuse integrators.

---

*Audit conducted using the Security Audit Playbook v2.8. All findings were verified using disprove-first methodology with exact file:line references.*
