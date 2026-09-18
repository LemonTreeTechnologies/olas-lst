# Audit 11 — Proof-of-Concept tests

These are self-contained Hardhat tests that run against the project's real contracts (real Gnosis
Safe, real Autonolas registries, real `ExternalStakingDistributor` / `Collector` / `MultisigGuard` /
`StakingTokenV1`). Each file inlines the full deployment in its `beforeEach`; no mocks beyond those the
project's own test suite already uses.

## Running

From the repository root (LayerZero libs are not installed, so temporarily rename `LzOracle.sol` as the
`test:hardhat` script does):

```bash
mv contracts/l1/bridging/LzOracle.sol contracts/l1/bridging/LzOracle._sol && \
npx hardhat test audits/audit11/poc/guard_balance.js audits/audit11/poc/double_fee.js ; \
mv contracts/l1/bridging/LzOracle._sol contracts/l1/bridging/LzOracle.sol
```

## Tests

### `guard_balance.js` — supports finding **I-1**
Demonstrates that a staker who controls an external-V1 service Safe **cannot capture protocol funds**,
despite `MultisigGuard` not checking the multisig token balance:
- the staking proxy gates `claim` / `checkpointAndClaim` / `unstake` to the recorded service owner
  (the `ExternalStakingDistributor`) — a direct call by any other account reverts;
- the real `ExternalStakingDistributor.claim` distributes the reward atomically (≈97.5% to the
  Collector/protocol, ≈2.5% to the staker's legitimate curating-agent share) and leaves ~0 on the Safe;
- the staker's real, guard-checked `execTransaction` sweep of the Safe therefore moves ~0.

### `double_fee.js` — supports finding **L-1**
Quantifies the double protocol fee on external-V1 rewards: with `Collector.protocolFactor = 10%`, an
external reward that the `ExternalStakingDistributor` split intended to send 80% to stOLAS holders
sends only 72% (the protocol take rises from 17.5% to 25.5%). Conservation holds — every wei stays
inside the protocol — so this is a fee-model question, not a loss.
