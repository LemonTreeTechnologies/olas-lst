# Modified Contracts — Pending Re-Deployment

This file tracks contracts whose source has been **modified** after their last on-chain
deployment but which have **not yet been re-deployed** ("modified but not updated").

Keep this list in sync whenever a deployed contract is changed, and clear an entry once
the corresponding contract has been re-deployed and its address updated in
`doc/configuration.json`.

## Pending audit8 / audit9 fixes

The following contracts were modified on the `post-audit` branch to address findings from
internal audits 8 and 9. The fixes were reviewed and verified correct in
[`audits/audit10/README.md`](audits/audit10/README.md) ("All 7 fixes verified correct.
No new vulnerabilities introduced."). They still require re-deployment.

| Contract | Layer | Changes |
|---|---|---|
| `contracts/l1/Depository.sol` | L1 | `_unstake` refund now sent to `sender` (original caller) instead of `msg.sender` |
| `contracts/l1/Treasury.sol` | L1 | `requestToWithdraw` now validates `msg.value`, forwards ETH to `unstakeExternal`/`unstake`; extracted `_processUnstakes` helper; added `WrongArrayLength` error |
| `contracts/l1/Distributor.sol` | L1 | `_increaseLock` resets dangling OLAS approval to 0 in the zero-lock branch |
| `contracts/l1/bridging/DefaultDepositProcessorL1.sol` | L1 | Removed `drain()` function and `Drained` event |
| `contracts/l2/ExternalStakingDistributor.sol` | L2 | `unstakeAndWithdraw` moves staking-proxy reads inside the service-unstake condition and validates `stakingProxy`/`serviceId` at entry; `reStake` uses `mapServiceIdCuratingAgents` instead of dead `mapCuratingAgents`; `setCuratingAgents` computes `stakingHash` outside the loop |

## Pending service re-deployment fix

`GnosisSafeSameAddressMultisig` has been removed from the `ServiceRegistryL2` multisig whitelist on
Gnosis, Base and Mode, so every `deploy()` routed through it reverts `UnauthorizedMultisig`. This
blocks `StakingManager` service re-deployment, which is a live liveness failure: services unstaked
by `StakingManager.unstake` sit in `PreRegistration` and the next `stake()` reverts.

| Contract | Layer | Changes |
|---|---|---|
| `contracts/l2/StakingManager.sol` | L2 | `_deployAndStake` re-deploys via `recoveryModule` instead of the de-whitelisted `safeSameAddressMultisig`, and registers the service under its own agent Id rather than the current immutable one; `safeSameAddressMultisig` slot deprecated and `recoveryModule` appended; new owner-only `changeMultisigImplementations`, which requires the implementations to be whitelisted in the service registry |
| `contracts/l2/ExternalStakingDistributor.sol` | L2 | Service creation deploys through the whitelisted `safeMultisig` with `safeSetupHelper` as the Safe `setup()` delegatecall target, replacing the pre-create plus `safeSameAddressMultisig` registration; `_createMultisigWithSelfAsModule` removed entirely, so the distributor is never a multisig owner; `safeSameAddressMultisig` immutable dropped, `safeMultisig` and `safeSetupHelper` appended as storage; `initialize` takes both, and a new owner-only `changeMultisigImplementations` sets them |

### New contract

| Contract | Layer | Purpose |
|---|---|---|
| `contracts/l2/SafeSetupHelper.sol` | L2 | Delegatecall target for Safe `setup()`, enabling the recovery module, the distributor and the guard as modules and setting the transaction guard. Required because the service registry creates service multisigs owned by the agent instances, so no protocol contract can wire them afterwards. Deploy once per chain. |

### Required post-upgrade transactions

Deployed proxies have none of the appended slots in storage, and both service re-deployment and service
creation revert `ZeroAddress` until they are set. Immediately after upgrading each implementation, run:

```bash
./scripts/deployment/deploy_l2_17_safe_setup_helper.sh <network>
./scripts/deployment/script_l2_11_change_multisig_implementations.sh <network>
./scripts/deployment/script_l2_12_change_external_multisig_implementations.sh <network>
```

### Known residue

The 20 services parked on the Gnosis staking pool `0x2da9ae6f…` were created with agent Id 69, while
the deployed implementation's immutable `agentId` is 85. Reading the agent Id from the service makes
them re-deployable again. That pool has `availableRewards == 0`, so no yield is affected.
