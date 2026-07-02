# Audit 11 — Full post-audit re-review

Focus: `main` branch — complete manual re-review of the whole protocol at commit
`019b21eea223ac74f93cfe5b124f88694d137983` ("Merge pull request #15 from post-audit").

## Scope

All in-scope contracts were read in full and reviewed by hand:

- **L1:** `stOLAS`, `Depository`, `Treasury`, `Distributor`, `Lock`, `UnstakeRelayer`,
  `bridging/DefaultDepositProcessorL1`, `bridging/GnosisDepositProcessorL1`,
  `bridging/BaseDepositProcessorL1`.
- **L2:** `StakingManager`, `ExternalStakingDistributor`, `StakingTokenLocked`, `ActivityModule`,
  `Collector`, `MultisigGuard`, `ModuleActivityChecker`, `StakingHelper`,
  `bridging/DefaultStakingProcessorL2`, `bridging/GnosisStakingProcessorL2`,
  `bridging/BaseStakingProcessorL2`.
- **Shared:** `Beacon`, `BeaconProxy`, `Implementation`, `Proxy`.

`bridging/LzOracle.sol` (LayerZero-driven staking-model management) is present in the source tree
but is **not part of the live deployment** (`doc/configuration.json` contains no `LzOracle`
address, and the live cross-chain path uses the native Gnosis AMB / Base bridge). It was therefore
treated as out of the live scope; its `Depository` hooks (`LzCreateAndActivateStakingModel`,
`LzCloseStakingModel`) are dormant while no `lzOracle` is set.

## Method

1. Full by-hand review of every contract, entry point and fund-movement path.
2. Regression check of every resolution from the prior internal audits (`audit1`–`audit10`) and the
   external CODESPECT report, confirming each fix is present and correct in the reviewed commit.
3. On-chain verification of the live L1 (Ethereum mainnet) deployment.
4. Runnable proof-of-concept tests, on the project's own real-contract test harness (real Gnosis
   Safe, real Autonolas registries), for the one exploit hypothesis that warranted a test and for
   the one accounting observation — see [`poc/`](poc).

## Verdict

**PASS — no exploitable vulnerabilities found (0 Critical / 0 High / 0 Medium).**

The codebase is mature. The one substantive item is a low-severity fee-model question (funds remain
within the protocol); the remainder are informational / hardening notes. The core ERC-4626 vault is
immune to donation, inflation and read-only-reentrancy manipulation because `totalAssets()` returns
internal accounting (`totalReserves`), never `balanceOf(this)`.

---

## Findings

### L-1 (Low) — External-staking (V1) rewards can be taxed twice

`ExternalStakingDistributor._distributeRewards` already splits an external service's reward into
collector / protocol / curating-agent shares (per the configured `protocolRewardFactor`) and sends
the collector share to `Collector` under the `REWARD` operation. Later, `Collector.relayTokens(REWARD)`
applies `protocolFactor` **again** to that same collector bucket before relaying the remainder to the
L1 `Distributor`. Because internal-staking and external-staking rewards share the single
`mapOperationReceiverBalances[REWARD]` bucket and `protocolFactor` is one global value, external
rewards are subject to two protocol cuts.

Quantified in [`poc/double_fee.js`](poc/double_fee.js) with `protocolFactor = 10%` and a reward `R`:

| Recipient | Intended (ESD split) | Actual after `relayTokens` |
|---|---|---|
| stOLAS holders (via Distributor) | 80.0% of R | **72.0% of R** |
| Protocol | 17.5% of R | **25.5% of R** |
| Curating agent | 2.5% of R | 2.5% of R |

Conservation holds — no funds leave the protocol (this is a protocol-treasury vs stOLAS-holder
re-allocation, not a loss) — but the effective external-staking yield delivered to stOLAS holders is
lower than the configured split implies.

**Recommendation.** Confirm the intended fee model. If only a single protocol fee is intended on
external rewards, either exempt the ESD-sourced collector bucket from `Collector.protocolFactor`, or
set `protocolRewardFactor = 0` in the external staking configs so the protocol fee is applied once.

### I-1 (Informational / hardening) — `MultisigGuard` does not constrain the service-multisig token balance

`MultisigGuard.checkTransaction` is empty, and `checkAfterExecution` validates only that the
external-staking-distributor and guard modules remain enabled and that the operator bond is not
slashed — it does not check the service multisig's OLAS balance. In principle the service Safe owner
(the `agentInstance` supplied at stake time) can therefore move any OLAS held by that Safe via a
guard-checked `execTransaction`.

This is **not currently exploitable for protocol funds**, and we verified so on the real contracts
(see [`poc/guard_balance.js`](poc/guard_balance.js)):

- The external staking proxies gate `claim` / `checkpointAndClaim` / `unstake` to the recorded
  service owner, which is the `ExternalStakingDistributor` (it is the account that calls
  `stake(serviceId)`). A direct call by any other account reverts. So a service reward reaches the
  Safe **only inside the atomic `ExternalStakingDistributor.claim` → distribute call**, which
  immediately splits it and leaves ~0 on the Safe.
- No other protocol OLAS is held on the service Safe (the staking deposit lives in the service
  registry token utility).

In the PoC, an account that stakes an external V1 service and controls the Safe ends up with only the
legitimate 2.5% curating-agent share; the protocol keeps ≥ 97.5%, and the owner's real `execTransaction`
sweep after distribution moves ~0.

**Hardening.** Consider having `MultisigGuard` reject an owner `execTransaction` that transfers the
staking token out of the multisig, so the "no standing balance on the Safe" invariant does not rely on
the claim-gating behaviour of externally-integrated staking proxies.

---

## Observations (Informational)

- **Treasury withdrawal finalization is time-based.** `withdrawDelay` must be configured at or above
  the worst-case L2→L1 unstake + bridge latency, otherwise `finalizeWithdrawRequests` reverts until
  the bridged OLAS arrives at the Treasury (a liveness property, not a loss; withdrawal tickets are
  minted for the full redemption value and the shortfall is unstaked from L2 on request).

- **`Depository.deposit` is permissionless and accepts `stakeAmount == 0`.** Called with zero, it lets
  any account move idle L1 reserve OLAS into owner-approved, Active L2 staking models. This is aligned
  with reserve utilisation, but a griefer could keep L1 reserve low and force withdrawals onto the
  slower L2-unstake path; the owner pause mitigates. Routing is limited to owner-approved Active models.

- **`DefaultStakingProcessorL2.redeem`** emits `RequestExecuted(operation = STAKE)` for a failed-stake
  request whose funds are redirected to the unstake reserve for return to L1. The event label reflects
  the original request; the fund movement is correct. Off-chain indexers keying on the event operation
  should account for this.

- **`BaseStakingProcessorL2.relayToL1`** passes the literal string `"0x"` (two bytes) as the bridge
  `extraData` rather than empty bytes; harmless for the OP-stack `withdrawTo`, but inconsistent with the
  Gnosis path.

- **`StakingTokenLocked.stake`** does not validate the staked service multisig's proxy hash. This is
  safe because `stake` is restricted to `StakingManager`, which is the sole minter of those multisigs;
  noted as a deviation from the base `StakingToken` pattern.

---

## Prior-audit regression check

All resolutions from `audit1`–`audit10` and the external CODESPECT report were re-verified present and
correct at the reviewed commit, including:

- ERC-4626 vault accounting uses internal `totalReserves` (not `balanceOf`), giving donation /
  inflation immunity; `deposit` and `redeem` round in the vault's favour.
- `DefaultStakingProcessorL2` initialises a queued failed request with a non-default status
  (`EXTERNAL_CALL_FAILED`) and redirects a failed deposit to the unstake reserve rather than
  re-attempting the stake; the request queue is replay-safe.
- Per-service curating-agent access (`mapServiceIdCuratingAgents[serviceId]`), the `create` vs `update`
  service flag, and the Safe-setup signature are correct.
- `Lock` has a withdraw path and its `increaseLock` pulls OLAS from `msg.sender` only (own-funds), so an
  outsider cannot lock the contract's idle balance.
- `Distributor` resets its dangling OLAS approval to the Lock on failure; the removed
  `DefaultDepositProcessorL1.drain()` is confirmed absent.
- `StakingTokenLocked.stake` is restricted to `StakingManager`; the manager can always reclaim staking
  slots via `unstake`, so there is no permanent slot exhaustion.

## On-chain verification (Ethereum mainnet)

The live `stOLAS` vault is wired to the correct `treasury` / `depository` / `distributor` /
`unstakeRelayer` proxy addresses — deployment was atomic and the unprotected `initialize` was not
front-run. At the time of review the vault held ≈ 4.04M OLAS in reserves against ≈ 3.42M stOLAS supply
(price-per-share ≈ 1.18), with internal accounting functioning as designed. The Depository owner is a
single account (governance is expected to move it under a timelock, per the roadmap) and the contract
is unpaused.
