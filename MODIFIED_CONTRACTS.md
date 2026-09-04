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

## Pending explicit staking access

A zero `stakingGuard` in a staking proxy config used to mean both "deliberately permissionless" and
"nobody configured a guard yet", and `stake()` treated the ambiguous case as open. Access is now stated
explicitly with an `openAccess` flag in the config word, `stake()` denies by default, and
`setStakingProxyConfigs` rejects a config carrying neither or both.

| Contract | Layer | Changes |
|---|---|---|
| `contracts/l2/ExternalStakingDistributor.sol` | L2 | `openAccess` flag added at bit 216 of the staking config, with `wrapStakingConfig` / `unwrapStakingConfig` extended; `stake()` grants non-owner access only via the flag or the staking guard curating-agent allowlist; `setStakingProxyConfigs` rejects ambiguous configs with a new `WrongStakingAccess` error; fixed `wrapStakingConfig` truncating the staking guard address |

### Config migration

Existing on-chain configs were written by the previous implementation and carry no `openAccess` flag.
Guarded proxies (all of Gnosis and Mode) keep working unchanged. The three **Base** proxies with a zero
staking guard **close** on upgrade and must be re-set with the flag in the same batch:

| Chain | Staking proxy | Collector / protocol / curating |
|---|---|---|
| Base | `0x0dfafbf570e9e813507aae18aa08dfba0abc5139` | 500 / 1000 / 8500 |
| Base | `0x66a92cda5b319dcccac6c1cecbb690ca3fb59488` | 500 / 1000 / 8500 |
| Base | `0x51c5f4982b9b0b3c0482678f5847ea6228cc8e54` | 500 / 1000 / 8500 |

The exposure window is harmless: creation on Base is blocked until the create-path fix ships anyway, and
`reStake` keys off `mapServiceIdCuratingAgents`, which this gate does not touch.

## Pending external reward bucket separation

`_distributeRewards` splits an external reward per the staking proxy config and used to send the
collector share to the shared `REWARD` bucket, where `Collector.relayTokens` applied its global
`protocolFactor` to it a second time. Internal and external rewards shared one bucket and one factor,
so neither could be exempted from the other.

| Contract | Layer | Changes |
|---|---|---|
| `contracts/l2/ExternalStakingDistributor.sol` | L2 | `_distributeRewards` tops up the new `EXTERNAL_REWARD` operation instead of `REWARD`, for both V1 and V2 staking types; the now unused `REWARD` constant removed |

**`Collector` is deliberately unchanged and does not need re-deployment.** `relayTokens` already applies
`protocolFactor` to the `REWARD` operation only, so routing external rewards to a different operation is
the whole fix.

### Required configuration

`EXTERNAL_REWARD` (`keccak256("EXTERNAL_REWARD")` =
`0xbe8fd53e4fd96c2b60bda3ce4ca9231d70aa14ec83b41918f888fb8b9f74363a`) must be registered on the Collector
with the **same L1 `Distributor`** receiver as `REWARD`, otherwise `topUpBalance` reverts `ZeroAddress`
and external reward distribution fails. Run before the distributor upgrade:

```bash
./scripts/deployment/script_l2_03_set_operation_receivers_collector.sh <network>
```

Off-chain agents relaying external staking rewards must switch to the new operation as well: the `REWARD`
bucket no longer receives them.

Note `Collector.protocolFactor` is `0` on Gnosis and Base today, so the double cut is latent rather than
active; nothing has been mis-split in production.

### Guard address truncation

`wrapStakingConfig` packed the staking guard as `uint160(stakingGuard) << 56`, which shifts within
`uint160` and silently drops the top 56 bits of the address. Any config built through that helper carried
a corrupted staking guard that no account could match, disabling `setCuratingAgents` for that proxy. Live
configs are unaffected — they were packed off-chain — but the helper is now correct.

### Known residue

The 20 services parked on the Gnosis staking pool `0x2da9ae6f…` were created with agent Id 69, while
the deployed implementation's immutable `agentId` is 85. Reading the agent Id from the service makes
them re-deployable again. That pool has `availableRewards == 0`, so no yield is affected.

## Pending MultisigGuard fixes

| Contract | Layer | Changes |
|---|---|---|
| `contracts/l2/MultisigGuard.sol` | L2 | `checkAfterExecution` releases the reentrancy lock before returning on an unsuccessful transaction; `checkTransaction` records the service multisig staking token balance and `checkAfterExecution` requires it not to have decreased; new `stakingToken` constructor parameter and `StakingTokenWithdrawn` error |

### Shared reentrancy lock

`checkAfterExecution` took the lock and returned early on `success == false` without releasing it. The
guard is a **single proxy shared by every service multisig on the chain**, so one failed Safe transaction
locked all of them out of owner transactions permanently, stopping liveness and therefore rewards. Safe
reaches that path whenever `safeTxGas` or `gasPrice` is non-zero, which the multisig owner controls.

### Staking token balance

Addresses I-1 from `audits/audit11`. A service multisig owner could move out any staking token sitting on
the Safe through a guard-checked `execTransaction`. Safe does not route module transactions past a guard,
so this constrains owner transactions only and never the distributor settling rewards.

Deployment note: `MultisigGuard` now takes the staking token address as a third constructor argument.
