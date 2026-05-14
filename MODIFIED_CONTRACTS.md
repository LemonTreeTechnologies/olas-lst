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
