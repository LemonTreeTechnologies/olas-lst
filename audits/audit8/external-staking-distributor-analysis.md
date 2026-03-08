# Detailed Analysis: ExternalStakingDistributor.sol (1,123 LOC)

**Date**: 2026-03-08
**Contract**: `contracts/l2/ExternalStakingDistributor.sol`

---

## Architecture Overview

The contract manages external staking services on L2 — creates Safe multisig wallets, stakes services in external staking proxies, handles reward distribution, and processes cross-chain unstake requests.

**Key roles:**
- `owner` — configures proxies, agents
- `l2StakingProcessor` — bridge endpoint (deposit/withdraw)
- `managingAgents` — can trigger unstake
- curating agents — can stake services (per-proxy access via `stakingGuard`)
- anyone — can call `claim`, `unstakeAndWithdraw` if evicted/no rewards

---

## Detailed Findings

### 1. `reStake` uses dead `mapCuratingAgents` mapping (lines 804, 244-245)

**Line 244:** `// UNUSED for now: Mapping whitelisted curating agent addresses`
**Line 245:** `mapping(address => bool) public mapCuratingAgents;`

**Line 804 (reStake):**
```solidity
if (!(mapCuratingAgents[msg.sender] || mapManagingAgents[msg.sender] || msg.sender == owner))
```

**But `stake` (line 610) uses:**
```solidity
curatingAgentAccess = mapStakingGuardHashCuratingAgents[stakingHash][msg.sender];
```

No function ever sets `mapCuratingAgents` to `true` — `setCuratingAgents` (line 912) writes to `mapStakingGuardHashCuratingAgents` instead. So the curating agent access check in `reStake` is dead code.

**Impact:** A curating agent who staked a service cannot restake it after eviction — only managing agents or owner can. No fund loss — managing agents/owner can still restake. Functionality limitation only.

**Severity:** Informational. The "UNUSED for now" comment suggests intentional deferral.

---

### 2. Reward distribution math — verified correct (lines 494-500)

```solidity
collectorAmount = (reward * collectorAmount) / MAX_REWARD_FACTOR;   // round DOWN
protocolAmount = (reward * protocolAmount) / MAX_REWARD_FACTOR;     // round DOWN
uint256 fullCollectorAmount = collectorAmount + protocolAmount;
uint256 curatingAgentAmount = reward - fullCollectorAmount;         // remainder → curating agent
```

Max dust loss: 2 wei per distribution (two round-downs). Curating agent absorbs remainder. Total always equals `reward`. **No issue.**

---

### 3. V1 DelegateCall to multiSend — verified safe (line 543)

```solidity
ISafe(multisig).execTransactionFromModule(multiSend, 0, msPayload, ISafe.Operation.DelegateCall);
```

Inner operations are all `ISafe.Operation.Call` (0x00). `multiSend` is immutable (line 220). MultiSendCallOnly rejects nested DelegateCall. **No issue.**

---

### 4. `unstakeAndWithdraw` permissionless path — verified safe (lines 697-702)

```solidity
if (stakingState == IStaking.StakingState.Staked && availableRewards > 0
    && !(mapManagingAgents[msg.sender] || msg.sender == owner)) {
    revert UnauthorizedAccount(msg.sender);
}
```

Anyone can unstake if evicted OR `availableRewards == 0`. Rewards go to collector/protocol/curatingAgent — caller gets nothing. **By design.**

---

### 5. `withdrawAndRequestUnstake` deficit accumulation — verified correct (lines 1005-1009)

```solidity
if (amount > olasBalance) {
    unstakeRequestedAmount = amount - olasBalance;
    amount = olasBalance;
    mapUnstakeOperationRequestedAmounts[operation] += unstakeRequestedAmount;
}
```

Deficit accumulates per operation. Fulfilled in `unstakeAndWithdraw` (lines 741-770) with partial fulfillment support. **Correct accounting.**

---

### 6. OLAS approve patterns — verified

- V2 line 553: `approve(collector, fullCollectorAmount)` → consumed by `topUpBalance(collectorAmount)` + `topUpProtocol(protocolAmount)`. Exact match.
- Line 764: `approve(collector, amount)` → consumed by `topUpBalance(amount)`. Exact match.
- Line 659: `approve(serviceRegistryTokenUtility, fullStakingDeposit)`. Consumed during deploy+stake. Correct.

No dangling approvals in normal flow. **No issue.**

---

### 7. `stakedBalance` accounting — verified

| Function | Operation | Line |
|----------|-----------|------|
| `stake` | `+= fullStakingDeposit` | 656 |
| `unstakeAndWithdraw` | `-= fullStakingDeposit` | 719 |
| `reStake` | no change (same deposit) | — |

Symmetric. `reStake` correctly leaves `stakedBalance` unchanged since it unstakes and restakes the same deposit. **No issue.**

---

### 8. `_createMultisigWithSelfAsModule` — verified safe (lines 338-401)

- Creates Safe with `address(this)` as initial owner
- Enables `address(this)` as module + guard as module
- Sets guard
- Swaps owner to `agentInstance`
- Uses contract signature (`r = bytes32(uint256(uint160(address(this))))`, `v = 1`)

After execution: agentInstance is owner, ExternalStakingDistributor and guard are modules, guard is set. **Correct setup.**

---

## Summary

| Area | Status |
|------|--------|
| Reward math | Safe — remainder absorbs rounding |
| DelegateCall | Safe — immutable target, Call-only inner ops |
| Balance tracking | Safe — symmetric stake/unstake |
| Access control | Functional — `reStake` curating agent check is dead code (informational) |
| Cross-chain deficit | Safe — accumulates and partially fulfills |
| Approve patterns | Safe — no dangling approvals |
| Reentrancy | Protected — `_locked` guard on all state-changing functions |

**No new bounty-qualifying vulnerabilities found.** The `mapCuratingAgents` dead code in `reStake` is consistent with what we already noted as a design observation — it's marked "UNUSED for now" by the developers.
