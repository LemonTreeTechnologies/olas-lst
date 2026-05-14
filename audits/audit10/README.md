# Audit 10 — Post-Audit Fix Review

**Audit Date:** March 24, 2026
**Commit Range:** `57d4094` (main) to `46f5737` (post-audit)
**Branch:** `post-audit`
**Repository:** `https://github.com/LemonTreeTechnologies/olas-lst`

## Objectives

Review of fixes addressing findings from internal audits 8 and 9, applied in the `post-audit` branch.
Verify that all fixes are correct, complete, and do not introduce new vulnerabilities.

## Scope

5 modified contracts, 2 commits (`40a349c`, `46f5737`):

```
contracts/l1/Depository.sol                        |   2 +-
contracts/l1/Distributor.sol                       |   3 +
contracts/l1/Treasury.sol                          | 109 ++++++++++++------
contracts/l1/bridging/DefaultDepositProcessorL1.sol|  24 -
contracts/l2/ExternalStakingDistributor.sol        |  48 ++++-----
```

## Findings

### Fix 1. Depository: refund sent to `msg.sender` instead of `sender`
```
File: contracts/l1/Depository.sol:324
Before: (bool success,) = msg.sender.call{value: refund}("");
After:  (bool success,) = sender.call{value: refund}("");
```
The `sender` parameter is the original caller passed through from Treasury.
When called via Treasury (which forwards `msg.sender` as `sender`),
the refund was incorrectly going to Treasury (`msg.sender`) instead of
the actual user (`sender`).

**Verdict: Fix correct. ✓**

### Fix 2. Distributor: dangling approval not reset
```
File: contracts/l1/Distributor.sol:89
Added: IToken(olas).approve(lock, 0);
```
In the `else` branch (when lock amount is zero and no lock is created),
a prior `approve(lock, olasAmount)` at line 79 leaves a non-zero allowance
on the Lock contract. The fix resets approval to zero.

**Verdict: Fix correct. ✓**

### Fix 3. Treasury: ETH value not forwarded to bridge calls during unstake
```
File: contracts/l1/Treasury.sol:142-213
Refactored into: _processUnstakes() internal function
```
The original `requestToWithdraw()` called `unstakeExternal()` and `unstake()`
without forwarding `msg.value` for bridge gas payments. Bridge calls on Gnosis
(AMB), Optimism (L1CrossDomainMessenger), etc. require native ETH for gas.
ETH sent by the user would remain stuck in Treasury.

The fix:
- Extracts `_processUnstakes()` helper (also resolves stack-too-deep)
- Tracks `remainingValue` across external and LST unstake calls
- Validates `externalAmounts.length == values[0].length`
- Forwards `{value: externalValue}` to `unstakeExternal()` and `{value: remainingValue}` to `unstake()`
- Rejects leftover ETH when no unstaking needed (`if (msg.value > 0) revert`)

**Verdict: Fix correct and complete. ✓**

### Fix 4. DefaultDepositProcessorL1: `drain()` function removed
```
File: contracts/l1/bridging/DefaultDepositProcessorL1.sol
Removed: function drain() external { ... }  (24 lines)
```
The `drain()` function allowed the owner to withdraw all native balance
from the deposit processor. Removed to reduce attack surface — leftover
refunds are handled via the existing `LeftoversRefunded` event path.

**Verdict: Fix correct. ✓**

### Fix 5a. ExternalStakingDistributor: guard checks moved inside service unstake condition
```
File: contracts/l2/ExternalStakingDistributor.sol:684-710
```
Previously, `availableRewards` and `stakingState` were read from `stakingProxy`
even when no service unstake was requested (`stakingProxy == address(0)` or
`serviceId == 0`). This caused reverts on invalid proxy addresses.

The fix moves all staking proxy reads inside the
`if (stakingProxy != address(0) && serviceId > 0)` block.

**Verdict: Fix correct. ✓**

### Fix 5b. ExternalStakingDistributor: curating agent access control per-service
```
File: contracts/l2/ExternalStakingDistributor.sol:803
Before: mapCuratingAgents[msg.sender]
After:  mapServiceIdCuratingAgents[serviceId] == msg.sender
```
Previously, any address in the generic `mapCuratingAgents` mapping could act
on ANY service. The fix restricts to per-service curating agents via
`mapServiceIdCuratingAgents[serviceId]`.

**Verdict: Fix correct. Addresses cross-service privilege escalation. ✓**

### Fix 5c. ExternalStakingDistributor: `stakingHash` computation moved outside loop
```
File: contracts/l2/ExternalStakingDistributor.sol:939
```
`keccak256(abi.encode(stakingGuard, stakingProxy))` was computed inside a loop
traversing curating agents. Since the inputs don't change per iteration,
this is a gas optimization only.

**Verdict: Fix correct (gas optimization). ✓**

## Summary

| # | Contract | Fix | Severity | Correct? |
|---|----------|-----|:--------:|:--------:|
| 1 | Depository | msg.sender → sender refund | Low | ✓ |
| 2 | Distributor | Reset dangling approval | Low | ✓ |
| 3 | Treasury | ETH value forwarding + validation | Medium | ✓ |
| 4 | DefaultDepositProcessorL1 | Remove drain() | Low | ✓ |
| 5a | ExternalStakingDistributor | Guards inside condition | Low | ✓ |
| 5b | ExternalStakingDistributor | Per-service curating agent access | Medium | ✓ |
| 5c | ExternalStakingDistributor | stakingHash outside loop | Gas | ✓ |

**All 7 fixes verified correct. No new vulnerabilities introduced.**
