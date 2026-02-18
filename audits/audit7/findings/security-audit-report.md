# Security Audit Report - External Staking Implementation

**Audit Date:** December 29, 2025  
**Commit Range:** `d7db0db` to `2d32914` (inclusive)  
**Branch:** `stake_external`  
**Version:** 0.2.0-pre-internal-audit

## Executive Summary

This audit reviews the security implications of the external staking implementation added to the olas-lst protocol. The changes introduce a new `ExternalStakingDistributor` contract and modify several core contracts to support external staking functionality.

**Files Changed:**
- New: `contracts/l2/ExternalStakingDistributor.sol` (787 lines)
- Modified: `contracts/l1/Depository.sol`, `contracts/l1/Treasury.sol`, `contracts/l2/Collector.sol`, `contracts/l2/StakingManager.sol`, `contracts/l2/bridging/*.sol`, `contracts/interfaces/IService.sol`

## Critical Findings

### CRIT-1: Incorrect Call Target in DefaultStakingProcessorL2.unstakeExternal ✅ CONFIRMED

**Location:** `contracts/l2/bridging/DefaultStakingProcessorL2.sol:244`

**Issue:**
```solidity
if (target == externalStakingDistributor) {
    bytes memory unstakeData = abi.encodeCall(IExternalStakingDistributor.withdraw, (amount, operation));
    (success,) = stakingManager.call(unstakeData);  // ❌ WRONG: calling stakingManager instead of externalStakingDistributor
}
```

**Severity:** CRITICAL

**Description:**
When processing an unstake operation for `externalStakingDistributor`, the code encodes the call correctly but then executes it against `stakingManager` instead of `externalStakingDistributor`. This will cause the unstake operation to fail or execute incorrectly.

**Impact:**
- External unstake operations will fail
- Funds may become locked in the external staking distributor
- Protocol functionality broken for external staking withdrawals

**Recommendation:**
```solidity
if (target == externalStakingDistributor) {
    bytes memory unstakeData = abi.encodeCall(IExternalStakingDistributor.withdraw, (amount, operation));
    (success,) = externalStakingDistributor.call(unstakeData);  // ✅ FIX: use externalStakingDistributor
}
```
[x] Fixed


---

## High Severity Findings

⚠️ **Note:** 
- HIGH-1 was reanalyzed and downgraded to MEDIUM (now MED-1). See [HIGH-1-reanalysis.md](HIGH-1-reanalysis.md).
- HIGH-2 was reanalyzed and downgraded to LOW (now LOW-1). See [HIGH-2-reanalysis.md](HIGH-2-reanalysis.md).
- HIGH-3 was reanalyzed and determined to be a **False Positive** (INFORMATIONAL). See [HIGH-3-reanalysis.md](HIGH-3-reanalysis.md).
---

## Medium Severity Findings

### MED-1: Missing Access Control in ExternalStakingDistributor.deposit ⚠️ REANALYZED (Formerly HIGH-1)

**Location:** `contracts/l2/ExternalStakingDistributor.sol:676-689`

**Issue:**
The `deposit` function allows any address to deposit OLAS tokens without access control:

```solidity
function deposit(uint256 amount, bytes32 operation) external {
    // Reentrancy guard
    if (_locked > 1) {
        revert ReentrancyGuard();
    }
    _locked = 2;

    // Get OLAS from l2StakingProcessor or any other account
    IToken(olas).transferFrom(msg.sender, address(this), amount);  // ❌ No access control

    emit Deposit(msg.sender, amount, operation);

    _locked = 1;
}
```

**Severity:** MEDIUM (downgraded from HIGH after reanalysis)

**Description:**
While the comment suggests it's intended for `l2StakingProcessor`, there's no actual access control check. However, after detailed analysis:

**Key Findings:**
1. `transferFrom` requires prior approval - attacker must intentionally approve tokens
2. Attacker loses control of deposited tokens - they can only be used by authorized functions (`withdraw`, `unstake`, `stake`)
3. No direct exploitation path - attacker gains nothing, loses tokens
4. However, creates accounting inconsistencies - `stakedBalance` is not updated, only actual balance increases
5. Inconsistent with `withdraw()` which has strict access control

**Impact:**
- ⚠️ Accounting discrepancies: `stakedBalance` doesn't reflect unauthorized deposits
- ⚠️ Inconsistent security model compared to `withdraw()`
- ⚠️ Potential confusion about who can deposit
- ✅ Not directly exploitable for profit (attacker loses tokens)

**Recommendation:**
Add access control for consistency:
```solidity
function deposit(uint256 amount, bytes32 operation) external {
    // Reentrancy guard
    if (_locked > 1) {
        revert ReentrancyGuard();
    }
    _locked = 2;

    // Check for authorized sender
    if (msg.sender != l2StakingProcessor && msg.sender != owner) {
        revert UnauthorizedAccount(msg.sender);
    }

    // Get OLAS from authorized sender
    IToken(olas).transferFrom(msg.sender, address(this), amount);

    emit Deposit(msg.sender, amount, operation);

    _locked = 1;
}
```

**Note:** See [HIGH-1-reanalysis.md](HIGH-1-reanalysis.md) for detailed analysis.

---
[x] Fixed

### MED-2: Missing Zero Address Check in setExternalStakingDistributorChainIds

**Location:** `contracts/l1/Depository.sol:94-95`

**Issue:**
The function allows setting `externalStakingDistributors[i]` to zero address:

```solidity
// Note: externalStakingDistributors[i] might be zero if there is a need to stop processing a specific L2 chain Id
mapChainIdStakedExternals[chainIds[i]] = uint256(uint160(externalStakingDistributors[i]));
```

**Severity:** MEDIUM

**Description:**
While the comment suggests this is intentional, allowing zero addresses can lead to issues in `depositExternal` and `unstakeExternal` which check for zero address and revert. This creates an inconsistent state where a chainId can be configured but operations will fail.

**Impact:**
- Confusion about which chainIds are active
- Operations will fail with `ZeroAddress` error instead of a clearer "chainId not configured" error
- Potential for accidental misconfiguration

**Recommendation:**
Either:
1. Explicitly check and revert if zero address is provided, OR
2. Add a separate mapping/flag to track disabled chainIds, OR
3. Update `depositExternal`/`unstakeExternal` to handle zero addresses gracefully with a clear error message

---
[x] Fixed

### MED-3: Inconsistent Reentrancy Guard Pattern

**Location:** Multiple locations

**Issue:**
The codebase uses two different reentrancy guard patterns:
- `Depository`: Uses boolean `_locked` (true/false)
- `ExternalStakingDistributor`: Uses uint256 `_locked` (1 = unlocked, 2 = locked)

**Severity:** MEDIUM

**Description:**
While both patterns work, the inconsistency can lead to confusion and potential bugs when integrating these contracts. The ExternalStakingDistributor pattern allows for more states but only uses two.

**Impact:**
- Code maintainability issues
- Potential confusion for developers
- Risk of incorrect guard implementation in future changes

**Recommendation:**
Standardize on one pattern across all contracts. The boolean pattern is simpler and sufficient for most cases.

---
[x] Noted, but left as is

### MED-4: Missing Array Length Validation in claim Function

**Location:** `contracts/l2/ExternalStakingDistributor.sol:767-768`

**Issue:**
The `claim` function has a TODO comment and uses a bare `revert()`:

```solidity
// TODO
// Check for correct array length
if (serviceIds.length != numProxies) {
    revert();  // ❌ Unnamed revert
}
```

**Severity:** MEDIUM

**Description:**
Using unnamed `revert()` makes debugging difficult and doesn't provide clear error information. The TODO suggests this was a placeholder.

**Impact:**
- Poor error messages for debugging
- Unclear failure reasons for users
- Inconsistent error handling

**Recommendation:**
Replace with a proper custom error:
```solidity
if (serviceIds.length != numProxies) {
    revert WrongArrayLength();
}
```
[x] Fixed

---

### MED-5: Potential Race Condition in mapAccountWithdraws Update

**Location:** `contracts/l1/Depository.sol:664, 1023, 285`

**Issue:**
The `mapAccountWithdraws` is updated in multiple places:
- Line 664: In `unstake()` function
- Line 285: In `unstakeExternal()` when operation is UNSTAKE
- Line 1023: Likely in another unstake path

**Severity:** MEDIUM

**Description:**
If both `unstake()` and `unstakeExternal()` can be called for the same sender in the same transaction (via reentrancy or complex flows), there could be accounting issues. However, the reentrancy guard should prevent this.

**Impact:**
- Potential double-counting if guards are bypassed
- Accounting discrepancies

**Recommendation:**
Ensure reentrancy guards are properly placed and consider adding explicit checks to prevent concurrent unstake operations for the same account.
[x] Noted, false positive

---

### MED-6: Missing Validation for ChainId Ordering

**Location:** `contracts/l1/Depository.sol:139, 228`

**Issue:**
There are TODO comments about checking chainIds for increasing order:

```solidity
// TODO check chain Ids for increasing order
```

**Severity:** MEDIUM

**Description:**
While not strictly a security issue, allowing unsorted chainIds could lead to:
- Gas inefficiency
- Potential duplicate processing
- Difficulties in off-chain tracking

**Impact:**
- Gas waste
- Potential for duplicate operations
- Off-chain tracking complexity

**Recommendation:**
Implement chainId ordering validation or document why it's not needed.
[]

---

## Low Severity Findings

### LOW-1: Potential Integer Overflow in mapChainIdStakedExternals Packing ⚠️ REANALYZED (Formerly HIGH-2)

**Location:** `contracts/l1/Depository.sol:921, 1018`

**Issue:**
The code packs address (160 bits) and amount (96 bits) into a single uint256 without explicit validation:

```solidity
// Packing: address in lower 160 bits, amount in upper 96 bits
mapChainIdStakedExternals[chainIds[i]] = uint256(uint160(externalStakingDistributors[i])) | (localStakedExternals[i] << 160);
```

**Severity:** LOW (downgraded from HIGH after reanalysis)

**Description:**
After detailed mathematical analysis:

**Mathematical Verification:**
- `type(uint96).max` = 2^96 - 1 = 79,228,162,514,264,337,593,543,950,335 (≈ 7.9 × 10^28)
- Maximum OLAS supply = 10^9 × 10^18 = 10^27 = 1,000,000,000,000,000,000,000,000,000
- **Safety margin:** 2^96 is approximately **79× larger** than maximum supply

**Packing/Unpacking Logic:**
- ✅ Packing logic is correct: `address | (amount << 160)`
- ✅ Unpacking logic is correct: `(packed >> 160)` for amount, `address(uint160(packed))` for address
- ⚠️ No explicit validation that amount ≤ type(uint96).max before packing

**Impact:**
- ✅ **Low risk:** Maximum supply (10^27) is well below uint96.max (7.9 × 10^28)
- ✅ **79× safety margin** provides significant protection
- ⚠️ **Defense in depth missing:** No explicit check (unlikely but possible corruption if limit exceeded)

**Recommendation:**
Add explicit check for defense in depth (optional but recommended):
```solidity
// Check that amount fits in 96 bits (upper bits of uint256)
if (localStakedExternals[i] > type(uint96).max) {
    revert Overflow(localStakedExternals[i], type(uint96).max);
}
```

**Note:** See [HIGH-2-reanalysis.md](HIGH-2-reanalysis.md) for detailed analysis.
[x] Noted, but too big to be reached

---

### LOW-2: Incomplete Error in claim Function

**Location:** `contracts/l2/ExternalStakingDistributor.sol:767-768`

**Issue:**
As mentioned in MED-3, the `revert()` without error message is a code quality issue.

**Severity:** LOW

**Recommendation:**
Use a proper custom error.
[x] Fixed

---

### LOW-3: Commented Out Code in _createMultisigWithSelfAsModule

**Location:** `contracts/l2/ExternalStakingDistributor.sol:336-351`

**Issue:**
Large block of commented-out code that should be removed:

```solidity
//        // TODO multisend maybe?
//        // Encode enable module function call
//        ...
```

**Severity:** LOW

**Recommendation:**
Remove commented code or move to documentation if it's needed for reference.
[x] Noted, will be removed

---

### LOW-4: Missing Event Emission for Some State Changes

**Location:** Various

**Issue:**
Some state changes don't emit events, making off-chain tracking difficult.

**Severity:** LOW

**Recommendation:**
Ensure all important state changes emit events for transparency and off-chain monitoring.
[x] Fixed

---

## Informational Findings

### INFO-1: Non-Standard Signature Pattern in _createMultisigWithSelfAsModule ⚠️ (Formerly HIGH-3)

**Location:** `contracts/l2/ExternalStakingDistributor.sol:327-328`

**Description:**
The code uses a non-standard signature pattern for Safe multisig transactions. However, this is **NOT a security vulnerability** because:
- The contract owns the Safe it creates
- This is an internal setup operation
- No external party can exploit this pattern

**Status:** ✅ **False Positive** - No security issue. See [HIGH-3-reanalysis.md](HIGH-3-reanalysis.md) for details.
[x] Noted

---

## Code Quality Issues

### Q-1: Inconsistent Error Messages

Some functions use custom errors, others use unnamed reverts. Standardize error handling.
[x] Fixed

### Q-2: Magic Numbers

Constants like `MAX_REWARD_FACTOR = 10_000` are good, but consider documenting why this specific value was chosen.
[x] Fixed

### Q-3: TODO Comments

Several TODO comments indicate incomplete implementation:
- ChainId ordering check
- Array length validation in claim
- Auto-calculation comment in unstakeExternal
[x] Fixed
---


