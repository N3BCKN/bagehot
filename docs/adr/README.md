# Architecture decision records

One file per decision, named `NNNN-short-kebab-title.md`, numbered from `0001` and never reused.

**An accepted ADR is never edited.** Changing a decision means writing a new ADR that supersedes
it: the new record says `Supersedes ADR-NNNN`, and the old one gets a single line added to its
Status field (`Superseded by ADR-MMMM`) — nothing else about it changes. Use `/spec-change` when a
decision looks wrong.

Status is one of `proposed` · `accepted` · `superseded by ADR-MMMM` · `rejected`.
An ADR is accepted only by the human; Claude writes them as `proposed`.

Once accepted, add the file to `.claude/protected-paths.txt` so it cannot be edited by accident.

## Template

```markdown
# ADR-NNNN: <decision in a single imperative phrase>

- Status: proposed
- Date: YYYY-MM-DD
- Prompt: PNN
- Supersedes: — (or ADR-MMMM)

## Context

What forces this decision: the constraint, the measurement, the part of the spec that depends on
it. Facts and numbers, not preferences. Link the spec section, invariant or data card involved.

## Decision

What we will do, stated so that code can be checked against it. Name the exact values, units and
rounding directions where they apply.

## Consequences

What becomes easier, what becomes harder, what this forecloses. Include the cost of reversing it.
Name the invariants, tests or report claims that now depend on this decision.

## Alternatives considered

Each with the reason it was not chosen. An alternative with no stated reason is not an
alternative, it is a note.
```

## Index

ADR-0001 to ADR-0015 are the blueprint's decision register (§6), written out in full. ADR-0016 to
ADR-0025 come from the prompt kit's "Corrections to the blueprint" and from decisions taken while
the specification was written. ADR-0026 was decided by the human at the P02 gate, and ADR-0027 at
the P03 gate via `/spec-change` CHG-002.

| ADR | Title | Status | Prompt |
|---|---|---|---|
| [0001](0001-usd-peg.md) | Peg the stablecoin to the US dollar | accepted | P04 |
| [0002](0002-weth-only-collateral.md) | Accept WETH as the only collateral | accepted | P04 |
| [0003](0003-strategy-immutable-per-deployment.md) | Fix the liquidation strategy at deployment | accepted | P04 |
| [0004](0004-redistribution-as-emergency-rung.md) | Redistribute before recording a deficit | accepted | P04 |
| [0005](0005-redemption-at-par-by-nicr.md) | Redeem at par against the lowest-NICR positions | accepted | P04 |
| [0006](0006-fixed-interest-rate.md) | Charge one fixed, per-second-compounded rate | accepted | P04 |
| [0007](0007-min-debt-and-gas-reserve.md) | Require a minimum debt and a gas reserve | accepted | P04 |
| [0008](0008-chainlink-and-sequencer-feed.md) | Read one Chainlink feed plus the sequencer feed | accepted | P04 |
| [0009](0009-immutable-contracts.md) | Deploy immutable contracts with no admin roles | accepted | P04 |
| [0010](0010-shutdown-pro-rata-settlement.md) | Settle a shutdown pro rata, in kind | accepted | P04 |
| [0011](0011-base-fork-as-experiment-environment.md) | Run the experiments on a Base mainnet fork | accepted | P04 |
| [0012](0012-python-model-and-differential-test.md) | Keep a Python model and test it differentially | accepted | P04 |
| [0013](0013-preregistration-and-block-bootstrap.md) | Preregister the analysis; bootstrap over blocks | accepted | P04 |
| [0014](0014-core-from-own-specification.md) | Write the core from our own specification | accepted | P04 |
| [0015](0015-wad-ray-explicit-rounding.md) | WAD/RAY with an explicit rounding direction | accepted | P04 |
| [0016](0016-gas-reserve-in-weth.md) | Pay the gas reserve in WETH; no native ETH | accepted | P04 |
| [0017](0017-rounding-via-oz-muldiv.md) | Divide only through OpenZeppelin `Math.mulDiv` | accepted | P04 |
| [0018](0018-solidity-version.md) | Pin solc 0.8.28, `evm_version = cancun`, transient guards | accepted | P04 |
| [0019](0019-deployment-chain-guards.md) | Guard the deployment chain ids; no raw signing keys | accepted | P04 |
| [0020](0020-raw-data-not-committed.md) | Keep raw data out of the repository | accepted | P04 |
| [0021](0021-one-shot-wiring.md) | One-shot `wire(...)` by the immutable deployer | accepted | P04 |
| [0022](0022-exact-integer-model-zero-tolerance.md) | Exact-integer model; zero differential tolerance | accepted | P04 |
| [0023](0023-penalty-cap-and-surplus-to-owner.md) | Cap the penalty; return the surplus to the owner | accepted | P04 |
| [0024](0024-oracle-gas-cap-and-post-failure-check.md) | Oracle gas cap and post-failure gas check | superseded by ADR-0030 | P04 |
| [0025](0025-survival-analysis-for-liquidator-latency.md) | Survival analysis for liquidator latency | accepted | P04 |
| [0026](0026-critical-tcr-redemption-gate.md) | Block redemptions below the critical TCR | accepted | P04 |
| [0027](0027-cancel-partial-redemption-below-mcr.md) | Cancel a partial redemption that would leave the position below MCR | accepted | P03 / CHG-002 |
| [0028](0028-document-rpow-error-bound.md) | Document rpow's bracket property and error bound in the specification | accepted | P10 / CHG-001 |
| [0029](0029-assembly-for-bounded-feed-reads.md) | Read the oracle feeds with a fixed-buffer assembly staticcall | accepted | P12 |
| [0030](0030-post-failure-gas-floor-covers-proxy-refunds.md) | Set the post-failure gas floor to ceil(2·ORACLE_GAS/63), capped at ORACLE_GAS | accepted | P12 / CHG-004 |
| [0031](0031-deploy-script-enforces-the-wired-peer-graph.md) | The deployment script enforces that the wired peer graph agrees | proposed | P11 / CHG-003 |

Numbering is continuous and never reused; a later decision takes the next free number, which is
not a position in the plan. **All 27 were accepted by the human at the P04 gate on 2026-10-23**,
ADR-0027 with the obligation that P16 lands the targeted test for the 11-wei partial and that it
passes against the Solidity, not only against the reference generator and the Python model. An
accepted ADR is never edited; changing one of these decisions means a new ADR that supersedes it.
ADR-0028 (CHG-001), ADR-0029 (P12) and ADR-0030 (CHG-004, superseding ADR-0024's bound) were
written after the gate and accepted by the human on 2026-10-23. ADR-0031 (CHG-003) is `proposed`
until the human accepts it.
