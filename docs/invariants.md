# Invariants I1–I16 and unit properties U1–U4

> **Written at P03** from `docs/spec.md` (approved at the P02 gate) and blueprint §16.2.
> Revised after the first `spec-auditor` pass, which found five false or unevaluable claims.
> Protected after the P03 gate; changes go through `/spec-change`.

An invariant is never weakened, skipped, `vm.assume`d away or deleted to make a run pass. A
failure is a bug in the code or in the spec: stop, report the counterexample, propose a fix. Use
`/debug-invariant`.

**How to read a section.** *Statement* is the property in words. *Formula* is exact, over contract
state and ghost variables the handler keeps — no prose is needed to implement it. *Tolerance* is
zero unless a derivation is given; an unexplained tolerance is a hidden bug. *Scope* says which
deployment (A = stability pool, B = Dutch auction) and which phase: **live** (before a shutdown
trigger), **window** (triggered, before `settle()`), **settled**. *Checked in* names the test on
each side. *Breaks if* lists sequences that would violate it if the code were wrong; those become
targeted tests, not just fuzz fodder.

**Ghost variables** kept by the Foundry handler and by the Python model's test driver
(`.claude/skills/invariant-testing/SKILL.md`): `gMinted`, `gBurned`, `gWethIn`, `gWethOut`,
`gDonatedWeth[c]`, `gDonatedToken[c]`, the I2 counters `gN`, `gX`, `gY`, per-actor deposit and
claim totals, and the three rational accumulators `gExactCollGain[a]`, `gExactInterestGain[a]`
and `gExactShare[a]` used by I3.
Donations are tracked because handlers deliberately make them (decision 3 of the P03 plan): the
spec says the protocol never reads `balanceOf` for accounting, and I1 turns that from an
assumption into a tested property.

**Reading values from events.** Where an invariant needs a quantity the contracts do not store —
which part of a liquidation went where, how many sub-effects an operation had — the handler reads
it from the emitted event named in the section, never by recomputing it. A test that recomputes
can agree with a buggy contract; an event field cannot.

## Summary

| id | Statement | Tolerance | Scope | Spec |
|---|---|---|---|---|
| I1 | Each holder's token balances equal its internal claims plus donations | 0 | both, all phases | §10.1 |
| I2 | Stable supply equals system debt within the derived drift bound | derived (§10.2) | both, live + window | §10.2 |
| I3 | Pool deposits and gains are covered by pool balances; `P` stays in range | 0 (sums), derived (per-depositor) | A | §6.6, §10.3 |
| I4 | A liquidation's effect on TCR is exactly characterised by the bundle that leaves the system | 0, and 1 wei of debt on a full-absorption liquidation and on an auction start (derived) | both, live | §6.4, §6.6.4, §6.8.2 |
| I5 | Every position redeemed from ends closed, or at `debt ≥ MIN_DEBT` and `ICR ≥ MCR` | 0 | both, live | §6.7.3 (with CHG-002) |
| I6 | Every liquidation conserves collateral and normalised debt across its buckets | 0 | both, live | §6.4.1, §6.6.4, §6.8.2 |
| I7 | Liquidation surplus reaches only the owner; the caller receives exactly `GAS_RESERVE` | 0 | both, live | §6.4.1, §6.6.4, §6.8.4 |
| I8 | No rounding shortfall: every claim is payable, and a full unwind leaves no one short | 0 | both, all phases | §8, §10.3 |
| I9 | `repay`, `addCollateral`, `close` succeed in every phase except settled, and never read the oracle | liveness | both, live + window | §5.1, §7 |
| I10 | After the trigger no new debt; after settlement claims are pro rata and bounded | 0 | both, window + settled | §6.11 |
| I11 | Parameters, wiring and strategy never change after deployment | 0 | both, all phases | §3, §9 |
| I12 | Operations that need a usable price do not execute without one | 0 | both, all phases | §7, §6.10.1 |
| I13 | The list is ordered by effective NICR within a calibrated absolute tolerance | calibrated (P02 measurement) | both, all phases | §6.3 |
| I14 | Mutable state rebuilt from events equals contract state | 0 | both, all phases | §11.1 |
| I15 | `redeem` reverts `TCRBelowCritical` exactly when the gate condition holds | 0 | both, live | §5.8, §6.7.2 |
| I16 | Every active auction is well formed | 0 | B, live + window | §10.3, §6.8 |
| U1 | `mulDivDown ≤ exact ≤ mulDivUp`, and `mulDivUp − mulDivDown ∈ {0,1}` | 0 | — | §2.2 |
| U2 | `rpow` is monotone in n and x and brackets the exact power | 0 | — | §2.3 |
| U3 | NICR sort keys are unaffected by interest accrual | 0 | both | §5.1.12, §6.3.1 |
| U4 | Σ compounded deposits ≤ pool stablecoin balance | 0 | A | §6.6.6 |

---

## I1 — Per-holder balances equal internal claims

**Statement.** For every contract that holds tokens, its WETH and stablecoin balances equal the sum
of the claims it records internally, plus anything donated to it. Donations are inert: they change
no protocol behaviour.

**Formula.** With `D_w(c) = gDonatedWeth[c]` and `D_t(c) = gDonatedToken[c]`, exactly:

| Holder | live and window | settled |
|---|---|---|
| VaultManager | `WETH.balanceOf = totalCollateral + pendingColl + activeCount·GAS_RESERVE + D_w` | `WETH.balanceOf = activeCount·GAS_RESERVE + D_w` |
| StabilityPool | `WETH.balanceOf = collGainsBalance + D_w` and `token.balanceOf = totalDeposits + interestGainsBalance + D_t` | unchanged |
| DutchAuctionHouse (B) | `WETH.balanceOf = totalLot + D_w` | `WETH.balanceOf = D_w` |
| DeficitLedger | `token.balanceOf = reserve + D_t` and `WETH.balanceOf = recoveredColl + D_w` | `token.balanceOf = D_t`, `WETH.balanceOf = D_w` |
| RedemptionModule | `WETH.balanceOf = D_w` and `token.balanceOf = D_t` | same |
| ShutdownModule | `WETH.balanceOf = D_w` before settlement | `WETH.balanceOf = claimColl − claimedColl + D_w` |

Supporting identities. Exact, and **scoped**, because `settle()` zeroes the aggregates while the
per-item records keep their last values (§5.1.11, §6.11.3):

| Identity | Phases |
|---|---|
| `totalStakes = Σ_active stake` | live, window — see below |
| `totalNormDebt = Σ_active normDebt + pendingNormDebt` | live, window — see below |
| `totalCollateral = Σ_active coll` | live, window — `onSettlement` sets it to 0 while positions keep `coll` |
| `totalLot = Σ_active lot` | live, window — `house.onSettlement` sets it to 0 while auctions keep `lot` |
| `auctionDebt = Σ_active debtRemaining` | live, window — `ledger.onSettlement` folds it into `deficit` |
| `activeCount = sorted.size` | live, window — `reclaimGasReserve` decrements `activeCount` only |

Every supporting identity stops at settlement, and `totalStakes` / `totalNormDebt` stop for a
second reason: `reclaimGasReserve` sets `status = ClosedByShutdown` and decrements `activeCount`
**without** zeroing `coll`, `normDebt` or `stake` and without touching the aggregates (§5.1.10),
and `onSettlement` voids every remaining position while "positions keep their stored fields"
(§5.1.11). So the first reclaim after settlement drops a position out of `Σ_active` while the
aggregates still carry it. After settlement only the holder-balance rows of the first table hold.

**Tolerance.** Zero. Every term is an integer the contract stores.

**Scope.** Both deployments, every phase, with the per-identity phases above.

**Checked in.** Foundry `invariant_I1_holderBalances` (one assertion per row, message naming the
holder) and `invariant_I1_supportingSums`; Medusa `property_I1_holderBalances`; Python
`model.invariants.check_I1(state)`; differential: both sides' `snapshot()` carry every term;
indexer monitor: recompute from events and compare with `balanceOf` each block.

**Breaks if.** A transfer updates no internal counter (or the reverse). Gas reserve paid twice, or
not released on `close` / full redemption / `reclaimGasReserve`. Pool dust swept to the ledger
without decrementing `totalDeposits` (§5.3.2). `recoveredColl` not credited on the no-stakes path
(§6.4.4). Auction leftover sent to the owner without reducing `totalLot`. **Targeted sequences:**
donate WETH and stablecoin to every holder, then run a full liquidation and a settlement; close a
position in the shutdown window, then call `reclaimGasReserve`; settle with auctions still active
and check the aggregates are zero while the records are not.

---

## I2 — Supply equals system debt, within the derived drift bound

**Statement.** The stablecoin supply accounts for exactly the system's debt, up to the rounding
drift the spec derives. The drift is bounded per operation and cumulative, not constant.

**Formula.** With `S = token.totalSupply`, `A = DeficitLedger.auctionDebt`, `F = deficit`,
`n = totalNormDebt`, `I = index`:

```
E  =  n · I − (S − A − F) · RAY
−gN · RAY  ≤  E  ≤  gX · I + gY · RAY
```

strict on the left when `gN ≥ 1`, strict on the right when `gX + gY ≥ 1` (§10.2).

**Counter rules.** Each *sub-effect* counts separately, so one transaction may bump several. The
handler increments from emitted events, not from its own model of what happened:

| Counter | Incremented by | Event it is read from |
|---|---|---|
| `gN` | every accrual with `dt > 0`, whether or not `interest > 0` | `InterestAccrued` |
| `gX` | `openPosition`, `borrow`; each partial repay, partial redemption, partial pool offset | `PositionUpdated` with `op ∈ {OP_OPEN, OP_BORROW, OP_REPAY}` only — the same event fires for `addCollateral`, `withdrawCollateral` and `liquidate`, which contribute 0 — plus `PositionRedeemed(closed=false)` and `PoolOffset` leaving `totalDeposits > 0` |
| `gY` | `close`; each full redemption; each full pool offset; each auction start; each no-stakes deficit record | `PositionUpdated(OP_CLOSE)`, `PositionRedeemed(closed=true)`, `PoolOffset` leaving `totalDeposits == 0`, `AuctionStarted`, `DeficitRecorded(source=NO_STAKES)` |

**An offset of zero adds nothing** (§10.2) — `dP == 0` emits no `PoolOffset`, so the
event-driven rule gets this right automatically. Redistribution, applying pending rewards, auction
purchases, shortfalls, `cover`, reserve and pool transfers and tips contribute `0`.

**Tolerance.** The bound *is* the derivation (§10.2); `E = 0` only at deployment. In stablecoin wei
the statement reads `−gN ≤ (system debt − (S − A − F)) ≤ gX·I/RAY + gY`.

**Scope.** Both deployments, live and window. **Not defined after settlement** — debts are
cancelled there, and I10 takes over.

**Checked in.** Foundry `invariant_I2_supplyDriftBound`; Medusa `property_I2_supplyDriftBound`;
Python `model.invariants.check_I2(state, counters)`; differential: `E`, `gN`, `gX`, `gY` compared
exactly each step (the P02 reference fuzz ran this on 60 seeds × 300 steps in both deployments);
vector `drift.json`; indexer monitor: recompute `E` per block and alert if the bound is approached.

**Breaks if.** Interest minted without raising `index`, or minted twice for one interval. A repay
that burns more than it cancels. An auction start that moves debt to `auctionDebt` without
removing it from `totalNormDebt`. A deficit recorded without the matching normalised-debt
reduction. **Targeted sequences:** accrue in blocks of 1 s for many steps (maximises `gN` without
moving anything else); open and close repeatedly at `MIN_DEBT`; liquidate with a partial offset
followed immediately by a no-stakes deficit (counts 1 to `gX` and 1 to `gY` in one call).

---

## I3 — Pool solvency and product–sum bounds

**Statement.** The pool can always pay what it owes: compounded deposits never exceed
`totalDeposits`, gains never exceed the balances they are paid from, and the product `P` stays in
its valid range so no liquidation can be blocked by a degenerate value.

**Formula.** Exact inequalities, every phase:

```
Σ_depositors compoundedDeposit(a)  ≤  totalDeposits
Σ_depositors collGain(a)           ≤  collGainsBalance
Σ_depositors interestGain(a)       ≤  interestGainsBalance
P_MIN ≤ P ≤ P_PRECISION
amount transferred by withdraw(a, x)  ==  min(x, compoundedDeposit(a) before the call)     (§5.3.2)
depositorCount[currentEpoch] == 0  and  not deficitLedger.settled()  ⇒  totalDeposits == 0  (§5.3.2)
```

The last clause carries its antecedent because §5.3.1 says the sweep is skipped once the ledger has
settled: "the residual stays in `totalDeposits`".

**Per-depositor attribution — two separate bounds, two separate mechanisms.**

*Gains* (§6.6.7, Appendix B item 4). The error runs in **both** directions, so the bound is
two-sided: the per-unit floor and the outer `mulDivDown` of R17 and per-scale floors of R31
under-credit, while the error carry over-credits — §6.6.7 says a carried remainder "is credited to
whoever is depositing at the next offset", and `perUnit_k` can exceed the exact share by up to
`err_{k−1}/T_k`. §6.6.7's own word is that a depositor's gain may *differ* from the exact pro-rata
share by up to `T / DECIMAL_PRECISION` per offset, not fall short of it. With
`gExactCollGain[a]` and `gExactInterestGain[a]` the rational pro-rata sums the test driver
accumulates at each event:

```
|gExactCollGain[a] − collGain(a)|  ≤  T_j / DECIMAL_PRECISION
                                      + Σ_{offset events k since snapshot} (T_k / DECIMAL_PRECISION + 1)
|gExactInterestGain[a] − interestGain(a)|  ≤  same form over interest events
```

summed over the events **since the depositor's last snapshot** — `deposit`, `withdraw` and
`claimGains` all re-snapshot (§6.6.8) — where `T_k` is `totalDeposits` at event k: it changes at
every event, so this is a sum, not a count times a constant. Interest events (§6.6.5, R15) have the
same structure as offsets and are counted the same way.

**The leading term is not optional.** `offset()` never clears `lastCollError` — it survives a full
offset, an epoch change and a complete emptying of the pool (§6.6.2) — so the carry paid out at the
first event after a snapshot may have been *generated* at an earlier event `j`, with a
`totalDeposits` unrelated to the depositor's. The over-credit at that event is
`err_{j} / DECIMAL_PRECISION ≤ T_j / DECIMAL_PRECISION`, and `T_j` can be arbitrarily larger than
every `T_k`. Worked case, inside §6.6.3's own `c ≤ 0.75·T` constraint: a pool with
`T_j ≈ 10^30` takes an offset leaving a carry near `10^30`; the pool empties; one depositor arrives
with `T_k = 10^18`; the next offset of `c = 10^12` credits them `2·10^12` against an exact share of
`10^12` — an over-credit of `10^12` wei against the two-wei allowance the per-event sum alone would
give. This is the same quantity §6.6.7 reports as its adversarial maximum, "1.6·10^12 wei" at
`T ≈ 10^30`: the bound is keyed to the `T` that produced the carry, not to the depositor's own.

*Compounded deposit* (R13, R16). A different mechanism: the error comes from flooring `P` itself,
bounded by one part in `P_PRECISION` per offset. With `gExactShare[a]` the rational value:

```
0  ≤  gExactShare[a] − compoundedDeposit(a)  ≤  gExactShare[a] · offsets_since_deposit / 1e27  + 1
```

**Tolerance.** Zero for the inequalities; the two attribution bounds are derived above. The totals
stay exact because the carries are kept.

**Scope.** Deployment A, every phase (after settlement the pool still works; only accrual and
liquidation stop).

**Checked in.** Foundry `invariant_I3_poolSolvency` and `invariant_I3_productRange` — the exact
inequalities and the `P` range only. **The two attribution bounds are checked in the Python model
and the differential, not in Foundry:** they compare against exact rationals, which Solidity cannot
carry, and approximating them with scaled integers would put a second, undeclared tolerance inside
a tolerance check. Python: `model.invariants.check_I3(state)` for the integer inequalities and the `P` range, and
`model.invariants.check_I3_attribution(state, exact)` for the two bounds, where `exact` holds the
`fractions.Fraction` accumulators. Medusa `property_I3_poolSolvency`; Halmos
`check_I3_proRataSumBounded` (one offset, symbolic deposits); differential: `P`, `currentScale`,
`currentEpoch`, `S` and `G` compared exactly; monitor: alert if `P` falls within 10× of `P_MIN`.

**Breaks if.** An offset that does not rescale `P` when it crosses `SCALE_FACTOR` (§6.6.2). A carry
dropped on an epoch change — the defect the P02 reference fuzz found, which over-credited
depositors by 671 wei. Dust swept while a depositor in the current epoch still exists.
**Targeted sequences:** offsets that take the pool to exactly `totalDeposits − 1` wei repeatedly
(drives `P` toward `P_MIN` and forces rescaling); deposit, full offset (epoch change), deposit
again, withdraw everything; two depositors, one offset, both withdraw (the P02 dust-sweep vector);
`withdraw(type(uint256).max)` as the documented "withdraw everything" idiom.

---

## I4 — What a liquidation does to TCR

**Statement.** A liquidation removes a precise bundle of collateral and debt from the system, and
its effect on TCR is determined by that bundle's ratio — not by the liquidated position's.

> **Two corrections, both found by audit.** The blueprint's "a liquidation does not lower TCR
> unless the position was uncollateralised" is false: removing collateral `c` and debt `d` gives
> `(C−c)/(D−d)`, which is at least `C/D` exactly when `c/d ≤ C/D`, so a position with
> `TCR < ICR(p) < MCR` lowers TCR. The first P03 draft corrected that to "ICR ≤ TCR ⇒ TCR does not
> fall", which is **also false in deployment A**: the bundle that leaves the system is not the
> position. When the pool absorbs only part of the debt, the redistributed remainder stays inside
> `systemColl` as `pendingColl`, so only `surplus + collP` leaves against `debtAbsorbed` of debt —
> a richer bundle than the position. Worked case: `ICR = 1.09`, penalty 5%, pool covering half the
> debt gives a removed-bundle ratio of 1.13, and with `TCR = 1.10` the liquidation lowers TCR while
> `ICR ≤ TCR` holds.

**Formula.** Let `C = systemColl`, `D = systemDebt` (§5.1.12), measured **after `accrue` and
`applyPending(id)` and before `sorted.remove(id)`**, and again at the end of the call — `accrue`
raises `D` without raising `C`, and that movement is I2's business, not I4's.

The bundle that leaves, read from `Liquidated` and (in A) `PoolLiquidation`:

```
A:  Δc = surplus + collP            Δd = debtAbsorbed
    (collReturned re-enters C as pendingColl, or as recoveredColl on the no-stakes path;
     normRest stays in totalNormDebt, or becomes deficit, and either way stays in D)
B:  Δc = 0                          Δd = 0           (coll moves to totalLot, debt to auctionDebt)
```

Asserted — **(A1)–(A3) in deployment A only, (B1)–(B2) in B only**. The labels are not
decoration: A2's hypothesis `debtAbsorbed == debt` is also true in B (§6.8.2 returns `(debt, 0)`),
where `Δc = 0 ≠ coll`, so applying the A clauses there would assert something false.

```
(A1)  C_after == C_before − Δc                                                  exact
(A2)  debtAbsorbed == debt  ⇒  Δc == coll  and  Δd == debt                      exact
(A3)  debtAbsorbed == debt  and  effColl·D_before ≤ debtOf(id)·C_before
         ⇒  C_after · D_before + C_before  ≥  C_before · D_after    (TCR fell by at most 1 wei of debt)
(B1)  C_after == C_before                                                       exact
(B2)  D_before ≤ D_after ≤ D_before + 1                                         (see tolerance)
```

**Not asserted, measured.** When `debtAbsorbed < debt` the removed bundle is richer than the
position whenever there is a surplus, and TCR can fall. The report measures the distribution of
`Δc·D_before − Δd·C_before` across liquidations; it is a property of the waterfall, not a defect.
Auction *purchases* are likewise excluded: they sell below the oracle price by design.

**Tolerance.** Zero except in (A3) and (B2), where the same rounding rule costs one wei of debt in
opposite directions.

*(A3).* `systemDebt` takes **one** ceiling over the aggregate, `mulDivUp(totalNormDebt, index, RAY)`.
Removing `n` reduces it by `δ = ⌈N·I/RAY⌉ − ⌈(N−n)·I/RAY⌉ ∈ {debt − 1, debt}`, so `D` can fall one
wei less than the position's own `debt`, and the premise — stated in terms of `debt` — does not
cover that wei. The gap is at most `C_before`, hence the `+ C_before` term. It is not a corner
case: two positions with the same ratio give `ICR == TCR` exactly, and the conclusion then fails
whenever the split costs a wei (verified: `index = 1.2345…e27`, two positions of `coll = 5e18`,
`n = 3000e18` → `δ = debt − 1`, shortfall exactly `C_after`).

*(B2).* An auction start splits one ceiling into two:
`systemDebt` counts `mulDivUp(totalNormDebt, index, RAY)` and adds `auctionDebt`, and §6.8.2 moves
`debtOf(n) = mulDivUp(n, index, RAY)` across. Since `⌈a⌉ + ⌈b⌉ ≥ ⌈a+b⌉` with a gap of at most 1,
`systemDebt` can rise by exactly 1 wei (verified: `index = 1.2345…e27`, `totalNormDebt = 1.2345…e23`,
`n = 2.3456…e19` gives +1). So an auction start can lower TCR by one wei of debt. That is the
rounding direction R1/R28 chose — debt never understated — not a leak.

**Scope.** Both deployments, live phase.

**Checked in.** Foundry `invariant_I4_liquidationBundle` (the handler reads `Δc`, `Δd` from the
events and checks A1/A2/B1/B2) and `invariant_I4_fullAbsorptionDoesNotLowerTcr` (A3); Python
`model.invariants.check_I4(before, after, events)`; differential: `C` and `D` are in `snapshot()`;
monitor: recompute per liquidation event.

**Breaks if.** Seized collateral credited to the pool but not removed from `totalCollateral`. An
auction start that forgets `deficitLedger.addAuctionDebt(debt)`, so debt vanishes from `D`. A
no-stakes remainder recorded as deficit without adding `recoveredColl` to `C`. **Targeted
sequences:** liquidate with the pool empty (`dP = 0`: no debt leaves, the surplus does — TCR falls
by design); with the pool exactly covering the debt (A2/A3 apply); with the pool one wei short;
liquidate the last position; in B, start an auction and check (B1)/(B2) before any purchase.

---

## I5 — Redemption leaves healthy positions

**Statement.** A redemption never leaves a position it took value from in a worse-than-allowed
state: each is either closed, or still has at least `MIN_DEBT` of debt and an ICR at or above MCR.

**Formula.** Quantified over the positions `redeemCollateral` actually **redeemed from** — the ones
that emitted `PositionRedeemed`, i.e. the full redemptions and the single partial — not over every
node the loop walked past:

```
for each id with PositionRedeemed(id, …):
    status(id) == ClosedByRedemption
      or  ( debtOf(id) ≥ MIN_DEBT  and  effColl(id)·price ≥ MCR·debtOf(id) )
```

Separately, about the nodes the loop **skipped** (no `PositionRedeemed` emitted for them):

```
for each id visited and not redeemed from:  effColl(id)·price < MCR·debtOf(id)   held at the visit
```

and: at most one position per call is partially redeemed, and it is the last one visited.

**Tolerance.** Zero.

> **Resolved by CHG-002 / ADR-0027.** Before the fix this clause did not hold: a partial redemption
> of a few wei against a position with no head-room above MCR could leave it fractionally below,
> because the debt relief `mulDivDown(d, RAY, index)` and the `mulDivUp` on the remaining debt
> together cancel up to `index/RAY + 1` wei less debt than the collateral taken. Reproduced at the
> **start** parameters (`MIN_PRICE = 10e18`); 57 of 300 index values in `[1.00, 4.00]` admitted a
> violating `d`. (An earlier claim in this file that the start configuration was safe came from an
> underpowered random search and was wrong.) §6.7.3 now carries a post-check that cancels such a
> partial exactly as a stale hint does — no state change, the loop ends — so I5 holds in every
> configuration and at every index, by construction. The targeted test must show the **affirmative**
> outcome, not merely the absence of a failure: on
> `redemption.json#partial_cancelled_below_mcr` the 11-wei call reverts `NothingRedeemed` with every
> field unchanged, and the 1,000-stable call on the same position succeeds and raises its ICR
> (1.1 → 1.101897).

**Scope.** Both deployments, live phase.

**Checked in.** Foundry `invariant_I5_redemptionLeavesHealthyPositions` plus targeted
`test_redeem_tinyPartialAtMcrBoundary`; Medusa `property_I5_redemptionHealthy`; Python
`model.invariants.check_I5(events, after)`; differential: position state compared per step.

**Breaks if.** The partial cap `d = min(remaining, debt − MIN_DEBT)` computed against stored rather
than effective debt. Pending rewards applied after rather than before the partial. The below-MCR
skip omitted. The CHG-002 post-check omitted, placed after the state change instead of before it,
or computed with stored rather than effective `c`, `n`. **Targeted sequences:** the CHG-002 vector
above, both steps; redeem exactly `debt − MIN_DEBT` from the tail; redeem against a position whose
pending rewards change its ICR.

---

## I6 — Per-liquidation conservation

**Statement.** A liquidation moves value between buckets and loses none of it. Every unit of the
position's collateral and of its normalised debt arrives somewhere the system accounts for.

> Replaces the blueprint's I6 ("system collateral plus recorded deficit covers obligations to
> holders"), which is not checkable as worded: in value terms a price fall breaks it by design, and
> in accounting terms it restates I2. Decision 2 of the P03 plan; the auditor confirmed the
> replacement is sound.

**Formula.** For one `liquidate(id)`, with `coll` and `n` the position's effective values before,
and every term read from `Liquidated` / `PoolLiquidation` / `Redistributed` / `DeficitRecorded`:

```
A:  coll == collP + surplus + collReturned                                   (§6.6.4)
    n    == normAbsorbed + normRest                                          (§6.4.1, R34)
    and collReturned is accounted exactly once: either redistributed (path REDISTRIBUTED,
    Redistributed.coll == collReturned) or sent to the ledger (path DEFICIT,
    DeficitRecorded.coll == collReturned)
    and normRest likewise: redistributed, or DeficitRecorded.amount == debtOf(normRest)
B:  coll == lotToAuction  and  n == normToAuction                            (§6.8.2)
both:  gasReserveToCaller == GAS_RESERVE
```

Provenance, so the test reads rather than recomputes: `Liquidated` carries `debtAbsorbed` and
`normRemainder`, so `n` comes from the position's preceding `PositionUpdated` and
`normAbsorbed = n − normRemainder`. `Redistributed` carries `errorColl` and `errorDebt` (§6.5.2),
the carried remainders; the identity `Σ_p pendingReward(p) + carry == distributed` is I8's
business, and the carry is named here only so the test does not recompute it. When
`collReturned == 0` **and** `normRest == 0`, neither `Redistributed` nor `DeficitRecorded` is
emitted and the conservation identity holds with those terms at zero.

**Tolerance.** Zero.

**Scope.** Both deployments, live phase.

**Checked in.** Foundry `invariant_I6_liquidationConservation`; Python
`model.invariants.check_I6(events)`; differential: liquidation return values and events compared
field by field; monitor: per liquidation event.

**Breaks if.** The remainder after a partial offset computed from the absorbed amount rounded the
wrong way (R34 fixes the direction). Recovered collateral neither redistributed nor credited to the
ledger. **Targeted sequences:** liquidate with an empty pool; with a pool holding exactly the debt;
with a pool one wei short; with no other active position (the no-stakes path).

---

## I7 — Surplus and the liquidation incentive

**Statement.** Whatever is left of a liquidated position after the penalty belongs to its owner,
and the only payment the liquidator receives is the gas reserve.

**Formula.** As a per-address delta map over the whole call, so that an owner who liquidates their
own position is handled correctly (they receive both, and the check must say so):

```
for every address a outside the core contracts, at the liquidation:
    ΔWETH(a)  ==  surplus · [a == owner]  +  GAS_RESERVE · [a == msg.sender]
    with surplus == 0 in deployment B: §6.8.2 sends the whole collateral to the lot and pays the
    owner nothing at the liquidation; their share arrives later, on the AuctionFinished(PAID) line
A:  seized == min(coll, mulDivUp(debt, WAD + LIQUIDATION_PENALTY, price))      (the cap, R11)
    surplus == coll − seized
B:  per buy:  ΔWETH(a) == slice · [a == who]  +  leftover · [a == auction.owner]
    where leftover is present only on AuctionFinished(PAID); on a non-finishing buy only the
    slice term appears. `who` receives the slice in the same call (§6.8.4) and is never a core
    contract (the data-carrying branch forbids those addresses explicitly).
    The starter's GAS_RESERVE is paid by liquidate itself (§6.4.1), not by the house
```

Core contracts are excluded because the collateral legitimately passes through them: §6.4.1 sends
`coll` to the strategy, and the no-stakes path sends `collReturned` to the DeficitLedger.

**Tolerance.** Zero.

**Scope.** Both deployments, live phase (an auction may finish during the window; the identity is
unchanged).

**Checked in.** Foundry `invariant_I7_surplusToOwnerOnly` (the handler snapshots every actor's WETH
balance around each liquidation and purchase); Medusa `property_I7_surplusToOwnerOnly`; Python
`model.invariants.check_I7(balances_before, balances_after, events)`; monitor: per event.

**Breaks if.** The surplus pushed to `msg.sender` instead of the owner. The penalty cap applied to
the wrong base. The gas reserve paid to the owner as well as the liquidator. **Targeted
sequences:** owner liquidates their own position (must not be profitable — threat T-10, and the
delta map must show `surplus + GAS_RESERVE` to one address); liquidate a position worth less than
the cap (surplus zero, no underflow); in B, buy the whole lot in one call.

---

## I8 — No rounding shortfall

**Statement.** Rounding never leaves the protocol unable to pay what it has promised. At any point
every recorded claim is payable, and a deliberate full unwind pays everyone out with nothing
missing.

**Formula.** The §10.3 inequalities, at every step:

```
Σ_active pendingColl(p) ≤ pendingColl ,  Σ_active pendingNorm(p) ≤ pendingNormDebt
Σ_depositors compoundedDeposit ≤ totalDeposits
Σ_depositors collGain ≤ collGainsBalance ,  Σ_depositors interestGain ≤ interestGainsBalance
Σ claims paid ≤ claimColl
```

**The unwind check** (`afterInvariant`), stated as a procedure because the phases differ and
several exits are legal only in some of them:

```
0. take an evm_snapshot (model: deep copy); the whole procedure is reverted afterwards, so the
   dealing in step 1 never leaks into I2's supply accounting
0b. call accrue() once, so the amounts dealt in step 1 match the final debts and every later
   call sees dt == 0. Without it, the first close() of step 2 accrues, every debt grows, and
   close reverts InsufficientBalance on the amount dealt. (No effect in the window: accrual is
   frozen, §6.11.2.)
1. give every position owner the stablecoin to cover their debt — the *effective* debt
   `debtOf(id)` of §5.1.12, including pending redistribution, since `close` burns it after
   `applyPending` (deal / model equivalent)
2. live or window phase:
     every depositor calls claimGains()  -> must succeed      (BEFORE withdraw: withdraw(max)
                                                               deletes the record, after which
                                                               claimGains reverts NoDeposit,
                                                               §5.3.1-§5.3.3)
     every depositor calls withdraw(max) -> must succeed      (pays remaining gains on the way out)
     every owner calls close(id)         -> must succeed      (§5.1.6, §6.11.2)
   settled phase:
     every owner of an Active position calls reclaimGasReserve(id)  -> must succeed
     every holder with a non-zero balance calls claim(balance)      -> must succeed
                                                               (a zero balance reverts ZeroAmount,
                                                                §6.11.4)
3. after step 2, for every core contract c:
     WETH.balanceOf(c)  == gDonatedWeth[c]  + residual(c)
     token.balanceOf(c) == gDonatedToken[c] + tokenResidual(c)
   and no per-position, per-depositor or per-holder claim is left unpaid
4. revert to the snapshot
```

**`residual` is named per contract, because several residues are permanent by design** and
asserting a bare balance of zero would fail on a correct implementation:

| contract | `residual` (WETH) | `tokenResidual` (stablecoin) | why it survives |
|---|---|---|---|
| VaultManager | `pendingColl` | — | §6.5.3: "Truncation dust stays in `pendingColl` / `pendingNormDebt` forever"; §6.5.4's `totalStakes == 0` branch exists for it |
| StabilityPool | `collGainsBalance` | `interestGainsBalance`, and `totalDeposits` once the ledger has settled | R14/R15/R17 floor every payout on both sides; §5.3.1 keeps the deposit residual after settlement |
| DeficitLedger | `recoveredColl` | `reserve` | collateral released only by `onSettlement` (§6.11.3); the reserve holds the interest share, B's penalties and swept dust (§5.6), the unwind never calls `cover()`, and `cover` would burn only `min(reserve, deficit)` (§6.9.2) |
| DutchAuctionHouse | `totalLot` of auctions the procedure did not buy out | — | the unwind does not buy |
| ShutdownModule | `claimColl − claimedColl` | — | `claim` floors (R26) |

The ledger's reserve is not merely left over: **the unwind creates it**. When the last depositor of
the current epoch withdraws, `leave(...)` sweeps the remaining `totalDeposits` to the ledger
(§5.3.1), so step 2 moves stablecoin into `reserve` itself. Each residual is a stored quantity that already
carries the right value in whichever phase the campaign ends: `pendingColl`, `recoveredColl`,
`reserve` and `totalLot` are zeroed by the settlement hooks (§5.1.11, §6.11.3);
`claimColl − claimedColl` is zero *before* settlement and appears only after it; and the pool's
floor residues exist in both phases, because the pool keeps working after settlement. So the table
needs no phase column.

The assertion is on the **transfers and the per-claimant residue**, not on every function being
callable in every phase: `liquidate` reverting `NotLiquidatable` for a healthy position and
`settle` reverting `WindowNotOver` before the window ends are correct behaviour, so the procedure
never calls them.

**Tolerance.** Zero. The inequalities are the direction the rounding table guarantees (R8, R9,
R13–R17, R26); a violation is a wrong rounding direction, not noise.

**Scope.** Both deployments, every phase.

**Checked in.** Foundry `invariant_I8_noRoundingDeficit` and the `afterInvariant` unwind; Medusa
`property_I8_noRoundingDeficit`; Halmos `check_I8_proRataSumBounded`; Python
`model.invariants.check_I8(state)` and `unwind(state)`; differential: every sum above is in
`snapshot()`.

**Breaks if.** Any `mulDiv` direction flipped from the §8 table. An error carry added instead of
subtracted. **Targeted sequences:** thousands of 1-wei operations against one position; a pool
offset leaving 1 wei; redistribute to a single position with 1 wei of stake.

---

## I9 — Liveness of the rescue paths

**Statement.** A borrower can always reduce risk or exit. `repay`, `addCollateral` and `close`
work in every phase except settled, at any ICR, and none of them reads the oracle.

**Formula.** For every call the handler makes with the spec's preconditions satisfied — `wired`,
`status == Active`, caller holds the tokens, `amount > 0`, `amount ≤ debt − MIN_DEBT` for a partial
repay, `msg.sender == owner` for `close`, hints exact, resulting collateral within the
`2^128 − 1` cap (`CollateralTooLarge`) — and with `settled == false`:

```
repay / addCollateral / close  must not revert
and the call must perform no oracle read   (the mock feed reverts if called, §7)
```

**Tolerance.** Not applicable: a liveness property, asserted inside the handler action rather than
as a state predicate. One documented exception, inherited from the spec: at the `2^128 − 1` supply
cap `accrue` reverts and takes every accruing operation with it (§5.9), which the spec accepts as
unreachable (~10¹¹× any realistic supply). The handler asserts the supply stays below the cap
rather than silently tolerating the revert.

**Scope.** Both deployments, live and window. After settlement these revert `SystemSettled` by
design and `reclaimGasReserve` is the remaining path.

**Checked in.** Foundry: handler actions assert success, `invariant_noUnexpectedReverts` catches
anything else, and the oracle mock turns an unexpected read into a hard failure; Python
`model.invariants.check_I9_liveness(op, state)`; differential: revert parity by error name.

**Breaks if.** An oracle read added to a rescue path (§7 forbids it). A mode check that catches
`repay` during the window. A hint requirement unsatisfiable on a large list. **Targeted
sequences:** repay while the oracle is unusable; add collateral during the shutdown window; close
the last position in the system.

---

## I10 — Shutdown creates no debt and pays pro rata

**Statement.** Once shutdown is triggered the system stops creating obligations, and after
settlement each holder can claim exactly their pro-rata share, never more than the pool holds.

**Formula.**

```
window:   no mint (no Transfer from address(0))
          totalNormDebt is non-increasing
          index is constant                                   (accrual frozen, §6.11.1)
          openPosition, borrow, withdrawCollateral, liquidate, redeem revert SystemShutdown
settled:  Σ claims paid == claimedColl ≤ claimColl
          each claim == mulDivDown(amount, claimColl, claimSupply)              (R26)
          order independence: the same claim multiset in any order yields the same per-holder totals
```

Order independence holds because `claimColl` and `claimSupply` are snapshots taken at `settle()`
and never re-read, so each claim is a pure function of its own amount. It is stated over the same
*multiset*: splitting one claim into two is not equivalent to making it once, since each floors
separately — that is R26 working as specified, not a violation.

**Tolerance.** Zero.

**Scope.** Both deployments; window and settled phases.

**Checked in.** Foundry `invariant_I10_noNewDebtAfterTrigger` and
`invariant_I10_claimsProRataAndBounded`; the order-independence check replays the same multiset in
a shuffled order from an `evm_snapshot` and compares totals; Medusa `property_I10_claimsBounded`;
Python `model.invariants.check_I10(state)`; differential: settlement snapshot fields compared
exactly.

**Breaks if.** Accrual not frozen, so debt grows during the window. The reserve burned after rather
than before the supply snapshot (§6.11.3, D-16). A claim computed against a live supply rather than
`claimSupply`. **Targeted sequences:** trigger, wait past the window, settle, then have every
holder claim in two different orders; claim twice from one holder; claim 1 wei.

---

## I11 — Immutability

**Statement.** Nothing about the deployment changes after wiring: no parameter, no wired address,
no strategy.

**Formula.** Snapshot in `setUp`, compare after every handler step:

```
∀ p ∈ on-chain parameters of §3.1:  getter(p) == snapshot(p)
∀ a ∈ wired addresses of §4:        getter(a) == snapshot(a)
wire(...)  reverts AlreadyWired for the deployer,  NotDeployer for anyone else        (§3.4)
```

Two exclusions, both explicit so the test needs no judgement:

- `ANNUAL_RATE`, `BASE_RATE_HALF_LIFE` and `AUCTION_HALF_LIFE` are deploy-script inputs with no
  on-chain getter (§3.1); they enter only through `RATE_PER_SECOND`, `BASE_RATE_DECAY` and `CUT`,
  which are compared. OracleAdapter has no `wire` at all.
- The static ABI check — "no deployed contract exposes a state-changing function outside the
  permission matrix" — is run against §9 **plus** the ERC-20 surface of §5.9
  (`transfer`, `approve`, `transferFrom`) and `wire` itself, which §9 covers separately.

**Tolerance.** Zero.

**Scope.** Both deployments, every phase.

**Checked in.** Foundry `invariant_I11_parametersImmutable`, `test_wire_secondCallReverts` and
`test_wire_nonDeployerReverts`; Python `model.invariants.check_I11(state)`; monitor: alert on any
`Wired` event after the first.

**Breaks if.** A setter introduced later. A "wired" address in mutable storage written by a hook.
**Targeted sequences:** call `wire` again as the deployer (`AlreadyWired`), as an attacker
(`NotDeployer`), and after settlement.

---

## I12 — No operation on an unusable price

**Statement.** Operations the spec marks "price required" do not execute when the oracle read is
unusable.

**Formula.** For `openPosition`, `borrow`, `withdrawCollateral`, `liquidate`,
`RedemptionModule.redeem` and `DutchAuctionHouse.reset`, with the oracle unusable for any of the nine reasons
of §6.10.1, by their code names in §11.1 and in the decision table's order (first match wins, so
the reason the adapter reports is the first applicable row, not the "worst" one):
`SEQUENCER_CALL_FAILED`, `SEQUENCER_DOWN` (answer ≠ 0), `SEQUENCER_INVALID`
(`startedAt == 0` or in the future), `GRACE_PERIOD`, `PRICE_CALL_FAILED`, `NON_POSITIVE`
(`answer ≤ 0` — row 6, which wins before the bounds row is reached), `INVALID_TIMESTAMP`
(`updatedAt == 0` or in the future), `STALE`, `OUT_OF_BOUNDS`:

```
provided every check §5 places BEFORE the price fetch passes,
    the call reverts PriceUnusable
    and no state changed
```

The proviso is load-bearing: §5 puts `PositionNotActive`, `NotOwner`, `ZeroAmount` and
`ZeroIterations` ahead of the fetch, so a call failing one of those reverts with *that* name, and
the differential test compares names.

Conversely, the operations §7 marks "not used" — `repay`, `addCollateral`, `close`,
`DutchAuctionHouse.buy`, pool `deposit`/`withdraw`/`claimGains`, `cover`, `accrue`, `claim`,
`reclaimGasReserve` — **never revert for an oracle reason** with the oracle unusable. They may
still revert for their own reasons (`withdraw` → `NoDeposit`, `buy` → `AuctionNeedsReset`). That
overlap with I9 is deliberate. `ShutdownModule.check` is in neither list: §7 marks it "fetched, not
required", and §6.11.1 requires it never to revert when no condition holds.

**Tolerance.** Zero.

**Scope.** Both deployments, every phase.

**Checked in.** Foundry `invariant_I12_noOperationOnUnusablePrice` (the handler toggles oracle
health as one of its actions, cycling all nine reason codes); Medusa `property_I12_priceGate`; Python
`model.invariants.check_I12(op, oracle_state, outcome)`; differential: revert parity by name;
vectors: `oracle.json` covers every row of the decision table.

**Breaks if.** An operation reads `lastGoodPrice` instead of requiring a usable read. The gas rule
(§6.10.3) omitted, letting a caller fake a failure. **Targeted sequences:** every row of §7 against
every unusable reason; a usable price that goes stale within the same block.

---

## I13 — Sorted order under redistribution

**Statement.** The list is ordered by effective NICR, descending, ties by lower id. Lazy
redistribution perturbs effective keys by rounding, so the order holds within a small absolute
tolerance rather than exactly.

**Formula.** For every adjacent pair `(A, B)` in the list — `A` nearer the head — with keys
`(cA, nA)`, `(cB, nB)` from `sortKey` (§5.1.12):

```
cA · nB  +  k · (cA + nB)  +  k²   ≥   cB · nA            with k = 4 wei
```

**Derivation of the form.** Each effective value is an exact value minus a non-negative floor
error: `c = c* − δc`, `n = n* − δn`, with `0 ≤ δ ≤ k` as the bounding assumption. The observed
order is consistent with a correct exact order when some admissible errors make it so; maximising
the left side and minimising the right gives `(cA + k)(nB + k) ≥ cB · nA`, which expands to the
check above. (With integer errors strictly below `k` the supremum is `(cA + k − 1)(nB + k − 1)`, so
the form is a safe over-approximation rather than the exact maximum.) Only the `A` side
carries the `k` terms — adding them to both sides as well would be strictly weaker.

**Why absolute and not relative.** A relative tolerance of the form
`τ = k(cA·nB + cB·nA)(1/cA + 1/cB + 1/nA + 1/nB)` — the first draft of this invariant — carries
cross terms like `k·cA·nB/cB`, which for a large `A` against a small `B` becomes astronomically
permissive and would wave through a gross inversion. It also cannot be evaluated: multiplying
through needs `cA·cB·nA·nB`, far past `2^256`.

**Overflow.** The check adds terms of order `2^131` to a product of order `2^209` under §6.3.1's
stated bounds (collateral capped at `2^128 − 1` and in practice bounded by WETH's supply,
normalised debt bounded by the `2^128` supply cap), so it fits in `uint256` exactly as the base
comparison of §6.3.1 does.

**The constant `k = 4` is calibrated, not proven.** §6.3.3 attributes the drift to stake and reward
rounding, "in particular for positions staked before the last snapshot", and a one-wei stake
deficit costs `ΔL / DECIMAL_PRECISION` wei of collateral — a quantity with no constant bound when a
large liquidation meets a small `totalStakes`. What is measured: P02 observed inversions up to
`7.1·10⁻¹⁹` relative, "about `1/min(effColl)` in wei" (§6.3.3), i.e. a one-wei-scale effect at
`min(effColl) ≈ 1.4·10¹⁸`. `k = 4` covers that with roughly 4× margin in absolute terms. **P17 must
re-validate against the invariant campaign and tighten `k` if the margin is larger than needed, or
escalate through `/spec-change` if the campaign exceeds it — never raise `k` to make a run pass.**

**Ties and the exact regime (CHG-005).** Call a list member *exact* if its key has not changed
since it was last inserted **and** every member of the list was exact at the moment of that
insertion. While **every** current member is exact, the list is exactly ordered by §6.3.1: for each
adjacent pair, `cA·nB > cB·nA`, or `cA·nB == cB·nA` and `idA < idB` — no tolerance. As soon as any
current member is not exact, every adjacent pair is held only to the tolerance check above, ties
included. The handler tracks exactness per member.

Both halves of the definition are needed. A key that changed without a reinsert breaks exactness
directly. A member inserted while another member was not exact may have been placed against that
member's changed key; it can then sit on the wrong side of an exact tie with a member whose key
never changed, and it stays there after the non-exact member has left the list. So "no current
member has drifted" is **not** sufficient. Counterexample (regression test
`SortedPositionsTest.test_CHG005_tieReversedThroughADriftedNeighbourThatHasSinceLeft`): B (id 12)
inserted; D inserted 3 wei above B, then its key lowered by 4 wei; A (id 19), with B's key, is placed
ahead of D; D removed — A sits directly ahead of B with equal keys, neither changed since insertion,
and no current member has drifted.

In the protocol a key changes without a reinsert when a redistribution adds pending rewards (§6.5).
A member becomes exact again when it is reinserted (any position operation) while every other
member is exact.

**Scope.** Both deployments, every phase. Insertion and hint validation are exact against the keys
they read, so the list is exactly ordered in the exact regime. Once any key has changed through
redistribution, the tolerance applies to every adjacent pair — including pairs whose own keys never
changed, for the reason given under "Ties and the exact regime".

**Checked in.** Foundry `invariant_I13_sortedByNicrWithinTolerance` (one walk, O(size); every run
must reach both the exact and the tolerance-only regime) and the CHG-005 regression test above;
Python `model.invariants.check_I13(state)` and `test_chg005_tie_reversed_through_a_drifted_neighbour_that_has_since_left`;
differential: the full list order is in `snapshot()`
and compared exactly between the two implementations — the tolerance is about reality, not about
the two sides disagreeing.

**Breaks if.** `sortKey` reads stored rather than effective values. Hints validated against a stale
key. A reinsert that does not remove first. **Targeted sequences:** two positions with NICRs one
wei apart, then a liquidation that redistributes to both; a position whose snapshot predates
several liquidations; a large liquidation against a small `totalStakes` (the regime where the
calibration is weakest); `MAX_HINT_STEPS` exceeded (must revert `StaleHint`, not mis-order).

---

## I14 — Events rebuild the mutable state

**Statement.** The event stream is a complete description of everything the system changes: an
indexer that sees only events reconstructs exactly the mutable state the contracts hold.

**Formula.** Replay every event since deployment into a fresh reconstruction; then for every
**mutable** field of §4:

```
rebuilt(field) == onchain(field)
```

covering positions (owner, status, coll, normDebt, stake, snapshots), list order, pool
accumulators keyed by `epoch:scale`, `lastErrorColl/Debt`, `pendingColl`/`pendingNormDebt`,
`depositorCount[e]`, auctions, ledger counters, oracle `lastGoodPrice` and `failureStart`, and the
shutdown snapshots.

**Immutables and `deployer` are excluded** and compared separately against the deployment manifest:
no event carries constructor arguments, and `Wired` carries only the wired addresses. §11.1's own
claim is about state *changes*, which is what this invariant tests.

**Tolerance.** Zero.

**Scope.** Both deployments, every phase.

**Checked in.** Foundry `invariant_I14_stateRebuildableFromEvents` (the handler records logs with
`vm.recordLogs`); Python `model.invariants.check_I14(events, state)`; the indexer's own suite (P41)
runs the same comparison against a fork.

**Breaks if.** A state change with no event, or an event missing a field the rebuild needs — the
reason §11.1 lists fields explicitly. **Targeted sequences:** every operation at least once,
including the rare paths (dust sweep, no-stakes deficit, auction reset, `reclaimGasReserve`).

---

## I15 — The critical-TCR redemption gate

**Statement.** A redemption is rejected exactly when the system is at or below the critical
threshold, on the same quantities the shutdown trigger uses.

**Formula.** Let `p` be the price the call fetched and `(live, C, D)` the three quantities of
`ShutdownModule.belowCritical` (§5.8), measured **immediately after the `AuctionCallbackActive`
check passes** and before `redeemCollateral` is called:

```
call reverts TCRBelowCritical   ⟺   live  and  D > 0  and  C·p < CRITICAL_TCR·D
```

A call with `D == 0` or `not live` is never rejected for this reason; if it passes the remaining
checks it reverts `NothingRedeemed`, having found nothing to redeem.

**Tolerance.** Zero.

**Scope.** Both deployments, live phase. The gate is measured before any `cover()`, the trigger
after its own, so the gate is never looser than the trigger and may be slightly tighter (§6.7.2) —
that asymmetry is deliberate and is *not* part of this invariant.

**Checked in.** Foundry `invariant_I15_noRedemptionBelowCritical` plus a targeted test calling
`redeem` from inside a buyer callback (the branch no vector covers — open issue P02-4); Medusa
`property_I15_redemptionGate`; Python `model.invariants.check_I15(...)`; vector
`redemption.json#tcr_guard`.

**Breaks if.** The gate reads `tcr()` (the rounded display view) instead of cross-multiplying. The
gate placed before `accrue()`, so `D` misses the current block's interest. `check()` called inside
`redeem`, which the revert would roll back. **Targeted sequences:** TCR exactly at `CRITICAL_TCR`
(must *not* revert — the condition is strict `<`); TCR between `CRITICAL_TCR` and MCR (must
succeed); redemption from inside an auction callback.

---

## I16 — Auctions are well formed

**Statement.** Every active auction is in a state its own rules can continue from.

**Formula.** For each `aid` with `active == true`:

```
tab ≥ debtRemaining ,  tab ≥ MIN_DEBT ,  lot > 0 ,  top > 0 ,  tic ≤ block.timestamp
Σ_active lot == totalLot ,  Σ_active debtRemaining == DeficitLedger.auctionDebt
activeAuctions == |{aid : active}|
```

**Tolerance.** Zero.

**Scope.** Deployment B, live and window (auctions continue through the window). **Not after
settlement:** `house.onSettlement` zeroes `totalLot` and sets `settled` without looping over
auctions, so the per-auction records keep their last `lot`, `tab` and `active` values by design
(§6.11.3) and the aggregate identities no longer hold. The records are stale on purpose, which is
why I16 stops at the window.

**Checked in.** Foundry `invariant_I16_auctionsWellFormed`; Medusa
`property_I16_auctionsWellFormed`; Python `model.invariants.check_I16(state)`; differential: every
auction field is in `snapshot()`.

**Breaks if.** The dust rule (`NoPartialPurchase`, §6.8.4) lets a purchase leave
`0 < tab < MIN_DEBT`. A finished auction left `active`. A reset that zeroes `top`. **Targeted
sequences:** buy down to exactly `MIN_DEBT`; attempt a purchase that would leave one wei under it;
reset at the `TAIL` boundary and at the `CUSP` boundary.

---

## Unit-level properties

These hold for the libraries themselves, independently of protocol state. U1 and U2 are tested at
P10; they are recorded here so the set is complete.

**U1 — rounding bounds.** `mulDivDown(x,y,d) ≤ x·y/d ≤ mulDivUp(x,y,d)`, and
`mulDivUp − mulDivDown ∈ {0,1}` with 1 exactly when `d ∤ x·y`. Zero tolerance. Foundry
`testFuzz_mulDiv_exactOrReverts`; Halmos `check_mulDiv_upMinusDownIsOneIffInexact`; pytest
`test_mul_div_is_floor_and_ceil_of_the_exact_quotient`. §2.2.

**U2 — `rpow`.** Monotone non-decreasing in `n` for `x ≥ RAY`, non-increasing for `x ≤ RAY`;
non-decreasing in `x`; `rpow(·,·,Floor) ≤ exact ≤ rpow(·,·,Ceil)`. Zero tolerance on all of those.
The *error bound* `|rpow − exact| ≤ n·max(1, exact/RAY)` is a separate, one-sided claim: pytest
`test_error_bound_holds_on_a_fresh_sample` checks it directly on 400 samples, while the Foundry
fuzz test `testFuzz_rpow_upMinusDownWithinTwiceTheBound` checks the two-sided consequence
(`up − down ≤ 2·n·factor`), which is weaker by a factor of 2. The bound is **not yet in the spec** —
CHG-001 proposes adding it to §2.3.

**U3 — NICR keys are accrual-invariant.** Sort keys use *normalised* debt, which accrual does not
change: for any two positions and any `index` change with no user operation, `precedes(kA, kB)` is
unchanged. This is why the list needs no reordering when interest accrues, and why the bounded hint
walk is safe. Zero tolerance. Foundry `testFuzz_sortKey_unchangedByAccrual`; Python
`test_nicr_order_stable_under_accrual`. `sortKey` is defined in §5.1.12; the order in §6.3.1.

**U4 — pool deposits are covered.** `Σ_depositors compoundedDeposit ≤ token.balanceOf(pool) −
interestGainsBalance − gDonatedToken[pool]`. Implied by I1 and I3 together; stated separately
because it is the single check the indexer monitor runs most often. Zero tolerance. Foundry
`invariant_U4_depositsCovered`; Python `model.invariants.check_U4(state)`. §6.6.6.

---

## Open items

| ref | Item | Where |
|---|---|---|
| CHG-002 | Resolved: §6.7.3's partial-redemption post-check (ADR-0027) makes I5 hold unconditionally; vector `redemption.json#partial_cancelled_below_mcr`. | `docs/changes/CHG-002-partial-redemption-mcr-rounding.md` |
| CHG-001 | `rpow`'s error bound, to be recorded in spec §2.3. Awaiting review. | `docs/changes/CHG-001-rpow-error-bound.md` |
| P02-4 | No vector exercises `redeem` from inside an auction buyer callback (I15). | `docs/progress.md` |
| I13 `k` | `k = 4` is calibrated to the P02 measurement, not derived. P17 re-validates and may tighten it; exceeding it is a `/spec-change`, never a bump. | this file, I13 |
| I4 partial | The TCR effect of a partial pool offset with surplus is measured, not asserted. The report must describe it, or it will read as a defect. | this file, I4 |
| I4 wei | A full-absorption liquidation can lower TCR, and an auction start raise system debt, by one wei each — both from the same aggregate-ceiling split (R1/R28). Stated in A3 and B2; worth one line in the report so neither reads as a leak. | this file, I4 |
