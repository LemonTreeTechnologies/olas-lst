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

## Re-deployed on Gnosis and Base — pending on Mode

The L2 contracts below were re-deployed and their proxies upgraded on **Gnosis** and **Base** on
2026-09-19, closing the service re-deployment and service creation blockers caused by
`GnosisSafeSameAddressMultisig` being de-whitelisted in the service registry.

**Mode still runs the previous implementations**, so these entries stay listed until it is updated.
Mode is deliberately deferred: its `StakingManager` holds no services, so nothing is stranded there,
and its two remaining external staking contracts can be handled with `reStake` instead.

| Contract | Gnosis | Base |
|---|---|---|
| `contracts/l2/StakingManager.sol` | `0xEBd4Be35dC3D6B2abdf2c72f3C2C9f67F848957e` | `0xeB7613bfbb40fab1DA73DC0b1c16Ec13639C305B` |
| `contracts/l2/ExternalStakingDistributor.sol` | `0x31e58449F1643c6B53Dc3d8B055b3e126525e6FC` | `0x0a9ab41778F4518b589926e608A4922407b06324` |
| `contracts/l2/MultisigGuard.sol` | `0xF0a109198822223dB8dd5b6dabd403cB83Ccfe70` | `0xd3AFDD71BB00112eCAb4baeA74B60C89F5C2a325` |
| `contracts/l2/SafeSetupHelper.sol` (new) | `0xeE908c14318e05D84a954A915870Ae476719656a` | `0x709e9010f2cf0aCB41f4Ca574Cd17445Cc03dBD6` |

`Collector` was deliberately **not** re-deployed: its operation gating already exempts anything other
than `REWARD` from `protocolFactor`, so routing external rewards to a new operation was sufficient.

### What shipped

- `StakingManager._deployAndStake` re-deploys via `recoveryModule` and registers the service under its
  own agent Id; `safeSameAddressMultisig` kept as a deprecated slot; owner-only
  `changeMultisigImplementations`, which requires the implementations to be registry-whitelisted.
- `ExternalStakingDistributor` creates services through the whitelisted `safeMultisig` with
  `safeSetupHelper` as the Safe `setup()` delegatecall target; `_createMultisigWithSelfAsModule`
  removed; `openAccess` flag at bit 216 with deny-by-default access and `WrongStakingAccess`
  validation; `wrapStakingConfig` staking-guard truncation fixed; rewards relayed through
  `EXTERNAL_REWARD` so the protocol factor cannot apply twice.
- `MultisigGuard` releases its shared reentrancy lock before the early return, and constrains the
  service multisig staking token balance.

### Configuration applied alongside the upgrade

- `EXTERNAL_REWARD` (`0xbe8fd53e4fd96c2b60bda3ce4ca9231d70aa14ec83b41918f888fb8b9f74363a`) registered on
  the Gnosis and Base Collectors with the same L1 `Distributor` receiver as `REWARD`.
- The three deliberately open Base staking proxies re-set with the explicit `openAccess` flag:
  `0x0dfafbf5…`, `0x66a92cda…`, `0x51c5f498…`.
- `changeMultisigImplementations` called on both the `StakingManager` and the
  `ExternalStakingDistributor` proxies, which is required because the appended storage slots read zero
  after an implementation upgrade.

### To update Mode later

```bash
./scripts/deployment/deploy_l2_17_safe_setup_helper.sh mode_mainnet
./scripts/deployment/deploy_l2_05_staking_manager.sh mode_mainnet
./scripts/deployment/deploy_l2_12_external_staking_distributor.sh mode_mainnet
./scripts/deployment/deploy_l2_14_multisig_guard.sh mode_mainnet
./scripts/deployment/script_l2_03_set_operation_receivers_collector.sh mode_mainnet   # before the ESD upgrade
./scripts/deployment/update_l2_staking_manager.sh mode_mainnet
./scripts/deployment/update_l2_external_staking_distributor.sh mode_mainnet
./scripts/deployment/update_l2_multisig_guard.sh mode_mainnet
./scripts/deployment/script_l2_11_change_multisig_implementations.sh mode_mainnet
./scripts/deployment/script_l2_12_change_external_multisig_implementations.sh mode_mainnet
```

Everything on Mode is owned by a single EOA, so no Safe transactions are involved. Note
`script_static_audit.sh` reports an error for the `ExternalStakingDistributor` section on Mode while it
runs the previous implementation, because `safeSetupHelper()` does not exist there yet.

### Known residue

The 20 services parked on the Gnosis staking pool `0x2da9ae6f…` were created with agent Id 69 while the
implementation's immutable `agentId` is 85. Reading the agent Id from the service makes them
re-deployable again, which the upgrade delivers. That pool has `availableRewards == 0`, so no yield is
affected.
