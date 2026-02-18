# CRIT-1 Fix: Incorrect Call Target in DefaultStakingProcessorL2.unstakeExternal

## Problem Confirmed

**Location:** `contracts/l2/bridging/DefaultStakingProcessorL2.sol:242-244`

### Current (Buggy) Code:
```solidity
if (target == externalStakingDistributor) {
    bytes memory unstakeData = abi.encodeCall(IExternalStakingDistributor.withdraw, (amount, operation));
    (success,) = stakingManager.call(unstakeData);  // ❌ BUG: calling wrong contract
}
```

### Comparison with Correct STAKE Implementation:
```solidity
// STAKE operation (CORRECT - line 215-222)
if (target == externalStakingDistributor) {
    IToken(olas).approve(externalStakingDistributor, amount);
    bytes memory stakeData = abi.encodeCall(IExternalStakingDistributor.deposit, (amount, operation));
    (success,) = externalStakingDistributor.call(stakeData);  // ✅ CORRECT: calling externalStakingDistributor
}
```

## Root Cause

This is a copy-paste error. When implementing the UNSTAKE logic, the developer copied the `else` branch pattern but forgot to change the call target from `stakingManager` to `externalStakingDistributor`.

## Impact

- **Critical:** External unstake operations will fail
- Funds may become locked in the external staking distributor
- Protocol functionality completely broken for external staking withdrawals
- The encoded call data is correct, but it's being sent to the wrong contract

## Fix

### Corrected Code:
```solidity
} else if (operation == UNSTAKE || operation == UNSTAKE_RETIRED) {
    // Note that if UNSTAKE* is requested, it must be finalized in any case since changes are recorded on L1
    // These are low level calls since they must never revert
    if (target == externalStakingDistributor) {
        bytes memory unstakeData = abi.encodeCall(IExternalStakingDistributor.withdraw, (amount, operation));
        (success,) = externalStakingDistributor.call(unstakeData);  // ✅ FIX: use externalStakingDistributor
    } else {
        bytes memory unstakeData = abi.encodeCall(IStakingManager.unstake, (target, amount, operation));
        (success,) = stakingManager.call(unstakeData);
    }
}
```

## Testing Required

1. **Unit Test:** Verify that when `target == externalStakingDistributor` and `operation == UNSTAKE`, the call goes to `externalStakingDistributor`
2. **Integration Test:** Test full flow of external staking unstake operation
3. **Regression Test:** Ensure regular (non-external) unstake operations still work correctly

## Verification Steps

After fix:
1. Deploy updated contract
2. Call `processRequest` with `target = externalStakingDistributor` and `operation = UNSTAKE`
3. Verify that `externalStakingDistributor.withdraw()` is called (check events/logs)
4. Verify that funds are properly withdrawn

## Status

✅ **Bug Confirmed** - This is a clear copy-paste error that must be fixed before deployment.

