# Audit 12 — delta re-review of the L2 service creation, guard and reward routing changes

Focus: `main` branch — review of the `contracts/l2` delta added after
[`audit11`](../audit11) and not covered by it or by the external report, at commit
`67766f630ed411359e4d519844e3ce698d4fcaf0` ("test(fork): prove wave-2 Base pools pay before any capital
moves").

## Scope

The commits that changed external service creation, the transaction guard and external reward routing:
`ExternalStakingDistributor`, `MultisigGuard`, `SafeSetupHelper` and `StakingManager`. The filter was
deliberately narrow — only issues reachable by an **unprivileged** participant. Owner, governance and
deployment-time findings were excluded by construction.

## Method

1. By-hand review of the delta, entry point by entry point, against the live configuration.
2. On-chain verification of the actual `mapStakingProxyConfigs` value of every configured staking proxy,
   because the `openAccess` flag is what separates "any account" from "a whitelisted curating agent".
3. Runnable proof-of-concept tests on the project's own harness (real Safe, real registries), plus fork
   tests against live state.

## Verdict

**1 High, resolved.** One issue was reachable by an unprivileged participant. It is fixed, deployed, and
confirmed against live state after deployment.

| # | Severity | Contract | Summary | Status |
|---|---|---|---|---|
| H-1 | High | `MultisigGuard` + `ExternalStakingDistributor` | Incomplete module-set check lets a staker permanently lock the staking deposit of their own seat | **FIXED** |
| H-2 | High | `MultisigGuard` | Staking-token balance snapshot can be re-taken from inside the transaction being checked, defeating the `audit11` I-1 remediation | **FIXED** |

`H-2` was found while remediating `H-1` and is not part of the reported delta.

---

## H-1 (High) — incomplete module-set check permanently locks a staking deposit — FIXED

### Mechanism

External services are created by `ExternalStakingDistributor.stake`. The caller supplies `agentInstance`,
which becomes the **sole owner** (threshold 1) of the service Safe that is created for it, and is recorded as
that seat's curating agent. The staking deposit and bond are paid from the distributor's own OLAS balance —
that is, from bridged protocol collateral, not from the staker.

The Safe is created with three modules — the recovery module, the distributor and the guard — and with the
guard installed as its transaction guard. In Safe's module linked list that is
`SENTINEL -> guard -> distributor -> recoveryModule`, so `prev(recoveryModule)` is the distributor.

`MultisigGuard.checkAfterExecution` asserted that the distributor and the guard were still enabled modules.
It never asserted the **recovery module**, and it did not forbid adding modules. It checked a subset and
treated that subset as the whole.

`ExternalStakingDistributor.unstakeAndWithdraw` calls `recoveryModule.recoverAccess` **unconditionally**.
`recoverAccess` moves ownership via `multisig.execTransactionFromModule`, which Safe rejects with `GS104`
once the recovery module is no longer enabled.

### Attacker and precondition

The sole owner of the service Safe. Where a pool is guard governed that is a whitelisted curating agent —
which the protocol's own threat model already treats as untrusted, per the `setCuratingAgents` docstrings.
Where a pool carries `openAccess`, it is **any account**, with no whitelisting at all, which is what makes
the flag the severity boundary. In both cases the attacker is not the owner and not governance.

### Exploit

1. Take a seat. The protocol pays `fullStakingDeposit = minStakingDeposit * (1 + numAgentInstances)` out of
   the distributor's balance. The attacker becomes sole owner of the created Safe.
2. As that owner, execute `disableModule(prev = distributor, recoveryModule)` through an ordinary
   guard-checked `execTransaction`. The guard permits it: the staking-token balance is unchanged, the guard
   is still installed, and the two modules it does check are still enabled.
3. `unstakeAndWithdraw` for that service now reverts at `recoverAccess`, for good. The deposit stays in
   `ServiceRegistryTokenUtility` against a service that can never be unstaked, and no distributor path can
   return it.

The cost to the attacker is gas; the deposit is protocol capital, not theirs. It is repeatable per seat, so
the damage scales to the whole OLAS balance the distributor has committed to external staking on that chain.

### Why it is griefing rather than theft, and why it is still High

The attacker gains no OLAS — the deposit is locked against a bricked service and is unreachable to them too.
The loss lands on stOLAS holders. Because `unstakeAndWithdraw` is atomic and reverts as a whole, `stakedBalance`
is unchanged and **keeps counting the locked OLAS as returnable collateral**, so the vault reports full backing
against a smaller real one: a silent under-collateralisation borne by holders at redemption. Meanwhile `claim`
and `reStake` never touch the recovery module, so a bricked seat keeps earning and its owner keeps collecting
their curating share.

The funds are frozen rather than destroyed — `terminate` and `unbond` do not need the Safe, since the service
NFT belongs to the distributor — but releasing them would require a distributor implementation upgrade to
decouple the deposit return from `recoverAccess`. The asymmetry is the point: cost is gas per seat, damage is
up to all externally staked collateral, and for a liquid staking token an emergency upgrade during live
withdrawals is a severe operational event in its own right.

### Why it was not caught earlier

The only test covering `disableModule` passed `prev = SENTINEL` for the recovery module. Safe rejects a wrong
`prev` on its own with `GS103`, before the guard's refusal is ever in question, so the test passed while
asserting nothing about the guard. The working `prev = distributor` was never exercised.

### Resolution

`checkAfterExecution` now asserts the **complete** module set:

- The recovery module is read from the distributor — where it is already a public immutable, so no
  constructor or deployment-script change was needed — and checked alongside the distributor and the guard.
- `getModulesPaginated(SENTINEL, 3)` must return exactly three entries **and** `next == SENTINEL`, so no
  module can be added either.
- The expected addresses are read fresh on every check rather than snapshotted before execution, because a
  snapshot taken before execution is itself tamperable (see H-2).

A new `UnexpectedModuleSet` error carries the multisig and the module count.

---

## H-2 (High) — the staking-token balance snapshot could be re-taken from inside the checked transaction — FIXED

The `audit11` I-1 remediation had `checkTransaction` snapshot the multisig's staking-token balance into
transient storage and `checkAfterExecution` revert if the balance had decreased. Nothing stopped the multisig
from calling back into `checkTransaction` **from inside the very transaction being checked**: batching
`[transfer OLAS out, guard.checkTransaction(...)]` through a MultiSend delegate call overwrote the snapshot
with the already-emptied balance, so the comparison in `checkAfterExecution` passed against itself.

As shipped, the balance constraint was therefore ineffective whenever OLAS sits on a service multisig.

### Resolution

`checkTransaction` is now first-write-wins per transaction: if a value is already recorded for that multisig,
it returns without overwriting. The snapshot is stored offset by one so that a recorded zero balance stays
distinguishable from nothing recorded at all, and `checkAfterExecution` reverts if nothing was recorded.

---

## Latent, not a finding

The staking-token constraint is a `balanceOf` snapshot, so a Safe owner could in principle move OLAS that is
resting on the Safe without changing `balanceOf`, via `approve` plus a later `transferFrom`. This is **not
reachable today**: an unprivileged party cannot make OLAS rest on a service multisig between transactions.
The staking proxy's `claim` is gated on `msg.sender == owner`, which is the distributor; `checkpoint()` on the
multisig moves nothing; and the distributor's `claim` sweeps the reward atomically within the same call. It
would become a real theft path if a future flow left OLAS on a service multisig across transactions. Recorded
here so that it is a known constraint on future changes rather than a rediscovery.

---

## Verification

- [`test/MultisigGuard.t.sol`](../../test/MultisigGuard.t.sol) — break tests for
  `disableModule(prev = distributor, recoveryModule)` with the `prev` that Safe's linked list actually accepts,
  for `enableModule`, and for the H-2 re-snapshot batch. All three fail against the previous implementation and
  pass against this one; the pre-existing tests in the file pass either way.
- [`test/LiquidStaking.js`](../../test/LiquidStaking.js) — the masked `disableModule` case now derives the real
  `prev` from the Safe's module list and asserts the recovery module is still enabled afterwards, so it fails
  against the previous implementation instead of passing vacuously.
- [`test/fork/MultisigGuardModuleSetFork.t.sol`](../../test/fork/MultisigGuardModuleSetFork.t.sol) — against
  live state: the previous implementation is shown to permit disabling the recovery module and the deposit then
  unrecoverable, the new one refuses it, and ordinary owner transactions plus a full `unstakeAndWithdraw` still
  work afterwards.
- [`test/fork/MultisigGuardGnosisLiveFork.t.sol`](../../test/fork/MultisigGuardGnosisLiveFork.t.sol) — against
  live state after deployment, deploying and patching nothing: it first asserts the guard proxy really is on the
  deployed implementation, so it cannot pass against the previous one, then that both module-set changes are
  refused while an ordinary owner transaction and a full `unstakeAndWithdraw` of the seat's entire deposit still
  succeed.

Because the constraint blocks every owner transaction on any Safe whose module set differs from the expected
one, each live seat was enumerated from the distributor's curating-agent records and confirmed to carry exactly
the three expected modules, ending at the sentinel, **before** the implementation was deployed.

## Deployment

The guard is a single proxy shared by every service multisig on a chain, so one `changeImplementation` applies
the constraint to every existing seat at once. No service Safe has to be touched and no service owner has to
cooperate.

| Chain | Implementation | Proxy |
|---|---|---|
| Base | `0xb5825653519C350257FcaD6171EFa9E52b0260dc` | `0x4D3911420a8E4E7dB8c979f4915dA8983C5e3ba2` |
| Gnosis | `0x53f6c9E1B9305C89987D3687d7C7fd32d1ea5AC3` | `0xBD645cf2D4F04A1c12B97fe2a8b4A09EF50F1896` |

Alongside the upgrade, the last Base staking proxy still carrying `openAccess` was closed and its reward
factors aligned with the other five, so that no pool grants a protocol-funded, solely-owned seat to an
arbitrary account. That proxy had no seats taken, so nothing was stranded.
