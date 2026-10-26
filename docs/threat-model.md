# Threat model

> **Written at P04 from blueprint §17 and `docs/spec.md`. Revisited at P38**, when the contracts
> exist and the security self-review can replace every "TBD" with a test name.

Bagehot is testnet-only and will never hold real funds. The threat model exists because the
research question is about behaviour under adversarial conditions: a mechanism that is only safe
against honest actors has not been compared fairly against one that is safe against all of them.
A threat here is anything that makes the system lose value, stop working, or — the failure mode
specific to a research protocol — **report a number that is not true**.

Section 3 is the register. Every threat names a mitigation that exists in the specification and
the invariant or test that is supposed to catch a regression. "TBD" means the test does not exist
yet and the prompt that will write it is named; those are collected in `docs/progress.md`.

## 1. Trust assumptions

Blueprint §17.1. The left column is what we rely on; the right is what we explicitly do not.

| Element | What we trust | What we do not trust |
|---|---|---|
| Borrower | Nothing beyond a valid signature | That they react to anything, repay in time, or avoid the edges of the rules |
| Liquidator | That they act for profit | That they arrive when it is unprofitable — latency is a measured random variable (ADR-0025), not an assumption |
| Pool depositor | That they maximise their own return | That they stay in the pool when losses approach (`docs/spec.md` §1.4) |
| Chainlink price feed | That it usually publishes a sensible price | That it is fresh, correct, or even callable at any given moment (§6.10) |
| Base sequencer | That it usually runs | Its availability, or neutrality of ordering: no mechanism depends on transaction order within a block |
| L1/L2 bridge, Base chain | That it behaves as documented | Nothing is staked on reorg resistance beyond the chain's own |
| Contract author | **Nothing** — there is no admin role (ADR-0009) and no upgrade path | That the code is free of defects; this is the main residual risk |
| Deployer key | That the human's key sends the one transaction that creates `BagehotFactory`; the factory's constructor deploys every contract and makes every `wire(...)` call, so each wired contract's `deployer` is the factory, and the factory has no function left that could wire anything again (P18, ADR-0021, P11-1) | That it stays secret forever — once the factory's constructor has run, neither the key nor the factory has any power at all. Deploying outside the scripted factory voids this (ADR-0031): the deploy script and smoke test assert `deployer() == factory`, `wired()` and the full peer graph |

Out of the model: a malicious or compromised privileged insider, because the design has no
privileged role to compromise. The one-shot `wire` is the only exception and it is spent at
deployment.

## 2. Assets and actors

| Asset | Where it lives | Who can move it, and under what rule |
|---|---|---|
| Position collateral (WETH) | `VaultManager` | Owner (`withdrawCollateral`, `close`, above MCR); liquidation; redemption at par; settlement |
| Gas reserve (WETH, per position) | `VaultManager` | Liquidator (A) or auction starter (B); returned on close or full redemption; `reclaimGasReserve` after settlement (ADR-0016) |
| Pool deposits (stablecoin) | `StabilityPool` | Depositor (`withdraw`); offset against liquidated debt (§6.6) |
| Pool gains (WETH + stablecoin) | `StabilityPool` | The depositor they are attributed to (§6.6.7) |
| Auction lot (WETH) | `DutchAuctionHouse` | Buyers at the curve price; leftover to the position owner; the whole lot to the claim pool at settlement |
| Protocol reserve (stablecoin) | `DeficitLedger` | `cover()` burns it against deficit; `RESET_TIP` to auction resetters; burned before the settlement snapshot |
| Claim pool (WETH) | `ShutdownModule` | Token holders, pro rata, after settlement (§6.11.4) |
| Stablecoin supply | `StableToken` | Minted only by `VaultManager` on borrow and accrual; burned on repay, redemption, offset, cover, settlement |

| Actor | Capability | Motivation |
|---|---|---|
| Borrower | Open, add, withdraw, borrow, repay, close; may be liquidated or redeemed against | Leverage; avoid liquidation cost |
| Liquidator / keeper | Call `liquidate`, `buy`, `reset`, `cover`, `check` — all permissionless | Gas reserve, penalty share, auction discount, tips |
| Pool depositor | Deposit, withdraw, claim gains | Penalty share and interest share, against the risk of absorbing losses |
| Redeemer | Exchange stablecoin for collateral at par less the fee | Arbitrage when the token trades below 1 USD |
| Auction buyer | `buy`, including a flash-style callback (§6.8.4) | Buy collateral below spot |
| Passive holder | Hold the token; claim at settlement | Hold a dollar-denominated asset |
| Researcher (the human) | Deploy, run experiments, publish | A defensible report |
| Outsider | Any public call, any ordering, any gas limit, arbitrary contracts | Profit, or disruption for its own sake |

## 3. Threat register

Verification column: `I*` are invariants (numbered in P03), otherwise a test family and the prompt
that writes it. "TBD" where nothing covers it yet.

| id | Threat | Vector | Impact | Likelihood | Mitigation | Residual risk | Test |
|---|---|---|---|---|---|---|---|
| T-01 | Redemption run below par | Once `systemColl · price < systemDebt`, each redemption lowers the TCR, so holders race and late holders get the remainder | Value transfer between holders; faster collapse | Medium in a crash | `redeem` reverts `TCRBelowCritical()` below `CRITICAL_TCR`, on the same quantities as the shutdown trigger (ADR-0026, spec §6.7.2) | Between `CRITICAL_TCR` and par redemptions still run; shutdown still needs somebody to call `check()` | `I15` (`RedemptionInvariantTest.invariant_I15_noRedemptionBelowCritical`); vector `redemption.json#tcr_guard`; B-callback branch `RedemptionAuctionCallbackTest.test_redeem_fromInsideABuyerCallback_revertsAuctionCallbackActive` (P16, against a mock house; the real house at P33) |
| T-02 | Oracle manipulation or failure | A wrong, stale or reverting feed; a compromised aggregator | Wrong liquidations, wrong redemption price, wrong auction start | Low per event, high impact | Freshness (`STALENESS`), bounds (`MIN_PRICE`/`MAX_PRICE`), positive-answer and future-timestamp checks, capped low-level `staticcall` with a 160-byte check (a short, malformed or junk reply is a failed call, never a revert; ADR-0029), operations that need a price revert `PriceUnusable`, prolonged failure triggers shutdown (ADR-0008, §6.10) | A feed that is wrong but inside the bounds is undetectable by the protocol `FEED_DECIMALS` is read once at construction: a Chainlink proxy phase change to an aggregator with different decimals (8 → 10 multiplies the price by 100, still inside the bounds) would be read as a usable wrong price — a bot or indexer check of `decimals()` against `FEED_DECIMALS` is the monitor (P11/P12 review F3). | `OracleAdapterTest` (every row and boundary, malformed replies, return/revert bombs), `OracleAdapterFuzzTest` (independent reference over the full table), `OracleVectorsTest` + `tests/model/test_oracle_model.py` (20 `oracle.json` vectors on both sides), `OracleAdapterForkTest` (real Base feeds), S6 |
| T-03 | Forged oracle failure by gas starvation | Caller supplies just enough gas that the 63/64 rule starves the feed call while the outer frame survives | Liquidations blocked; repeated, it forces an `ORACLE` shutdown | Low | `ORACLE_GAS` cap plus `gasleft() >= ORACLE_POST_FAILURE_GAS ≥ ceil(2·ORACLE_GAS/63)` after a failed call — the factor 2 covers the gas a proxied feed hands back (ADR-0030, superseding ADR-0024's bound; §6.10.3) | A feed that genuinely fails is still indistinguishable from one that is griefed at the source | `OracleAdapterGasTest`: separate step-1 sweeps of the sequencer call and the price call (and the price call after an expensive sequencer) — every gas limit yields a usable price or a revert, never a recorded failure; `test_gasRule_starvedCallReverts`, `test_gasRule_genuineOutOfGasIsRecordedWithEnoughCallerGas`; regression sweeps `test_regression_proxiedFeed_*` (mock proxy, every `just test`) and `OracleGasRuleForkTest` (Base's real proxy, `just test-fork`) |
| T-04 | Liquidation on stale state after a sequencer restart | The first blocks after an outage carry user state nobody could update | Liquidations that the borrower had no chance to prevent | Low | Sequencer-uptime feed plus `GRACE_PERIOD`; prices are unusable during the grace window (§6.10.1) | Grace period length is a parameter: too long blocks real liquidations, too short admits them | `test_row4_gracePeriodBoundary` (≤ is inside the grace window), `test_row3_sequencerStartedAtZeroOrFuture`, `test_lazy_priceFeedNeverCalledWhenTheSequencerDecides`; `oracle.json` sequencer rows; S7 |
| T-05 | Positions too small to be worth liquidating | Open at just above `MIN_DEBT`, then let the position decay in a high-gas regime | Bad debt accumulates in dust positions | Medium | `MIN_DEBT` floor plus a WETH `GAS_RESERVE` paid to whoever does the work (ADR-0007) | Parameters are calibrated for measured costs; an extreme L1 fee spike can still invert the economics | `I5` (position floors); cost model P24; S4 |
| T-06 | Stale-price arbitrage at settlement | Claim against the last good price when the oracle is the reason for the shutdown | Early claimants take more than their share | Low | Pro-rata in kind, no price read at settlement, order-independent claims (ADR-0010, §6.11.3–4) | Borrowers who do not repay in the window forfeit surplus collateral (§4 below) | `I10` (claim order independence); `shutdown.json` |
| T-07 | Run on the stability pool before a liquidation | Depositors withdraw as losses approach, leaving the pool empty exactly when it is needed | Loss falls to redistribution, then to the deficit | High by design | None — it is a measured phenomenon, not a defence (spec §1.4). The waterfall absorbs the consequence (ADR-0004) | Deployment A's headline result depends on depositor behaviour, which the agents model | Depositor agent (P26); S3; compared against B |
| T-08 | First-depositor / share-inflation attack on the pool | Donate to the pool before the first real deposit to skew the share price | Theft from the first depositor | Low | No shares: the product–sum accounting has no share price to inflate. `MIN_DEPOSIT`, epochs, scales and error carries instead of virtual shares (kit correction 1, D-8) | Donations still perturb I1 equalities; P03 decides whether handlers donate | `I3`; Halmos (P37); `product_sum.json` |
| T-09 | Product–sum precision failure | Repeated near-total offsets drive `P` toward zero; carries lost across scale and epoch changes | Depositors under- or over-credited; in the worst case liquidations revert | Medium without care | `P` at 36 digits, `P_MIN`, bounded rescaling loop, epochs, `SCALE_SPAN`, carries independent of `P` (§6.6) | Attribution is exact in total, per-depositor only to within the stated bound | `I3`; Medusa; differential test; pool stress fuzz (done at P02) |
| T-10 | Profitable self-liquidation | Owner liquidates their own underwater position to capture the penalty | Protocol pays the owner for their own default | Low | Penalty capped at `debt × (1 + penalty)` and the surplus returns to the owner either way (ADR-0023) | None material: the owner pays the penalty whichever account calls | `I7`; `VaultManagerLiquidationTest.testFuzz_selfLiquidation_notProfitableBeyondGasReserve` (P20: self = third party + `GAS_RESERVE` exactly, never above closing, also as the pool's only depositor); B at P33 |
| T-11 | Sorted-list griefing | Fill the list with positions, or pass hints that force long walks | Liquidations and redemptions run out of gas | Medium | `MAX_HINT_STEPS` bounds every walk; a bad hint reverts `StaleHint` rather than walking the list; redemption iterations are caller-supplied (§6.3) | A long run of below-MCR positions still consumes redemption iterations | `I13` (order); gas tests (P13); `sorted_list.json` |
| T-12 | Redemption front-running | Observe a redemption and reorder around it | Redeemer gets a worse position set | Low | Order-independent outcome per position; `maxFeeRate` bounds the fee the redeemer accepts; the fee rises with volume (§6.7) | MEV on Base is sequencer-ordered; no in-protocol defence | Fee tests (P16); `redemption.json` |
| T-13 | Auction front-running / price manipulation at `buy` | Jump ahead of a buyer, or move the oracle before a `reset` sets a new `top` | Buyer pays more than intended; lot sells too cheap | Medium | `maxPrice` on every `buy`; `reset` is rate-limited by `TAIL` and `CUSP`; `top` comes from a usable oracle price × `BUFFER` (§6.8) | The curve is public; competition for the lot is the mechanism, not a bug | Unit tests (P33); `auction.json` |
| T-14 | Auction callback reentrancy | `onAuctionPurchase` re-enters the system while the house's payment is incomplete | Inconsistent state read or written mid-purchase | Medium | Callback is supported deliberately (kit correction 13): house state final before the call, house lock held, target restrictions, transient `inPurchase()`; `check` and `redeem` refuse to run while it is set (§6.8.4, D-25, ADR-0026) | Views can show the intermediate state; any new reader of `systemColl`/`systemDebt` must take the same guard | `AuctionCallbackActive` on `check`/`buy` TBD (P33); redeem from a buyer callback: `RedemptionAuctionCallbackTest` (P16, mock house); no vector (the recorder cannot drive a callback, P02-4) |
| T-15 | Reentrancy elsewhere (tokens, hooks) | A malicious recipient or a hook that calls back | Double spend of a bucket; broken accounting | Low | Checks-effects-interactions, one transient lock per token-holding contract, WETH only, no native ETH, lock-free callbacks restricted to one caller (ADR-0016, ADR-0018, §5.10) | WETH is trusted to be a plain ERC-20 **with no transfer hook**. The redemption loop depends on it explicitly (P16 review F8): `_redeemFull` pushes WETH to each owner mid-loop and `redeem` records the base rate after `redeemCollateral` returns, which is safe only because WETH9 cannot call back (and both locks are held regardless) | Slither; reentrancy unit tests (P14–P21); `RedemptionReentrancyTest` re-enters from a hooked WETH and is blocked by both locks |
| T-16 | Volume attack on redemption | Redeem in size to force the system through positions cheaply | Peg floor exploited; borrowers redeemed against en masse | Medium | Base rate rises with redeemed volume and decays with time; fee charged on the requested amount (§6.7.1) | A patient redeemer still pays only the floor fee | Fee tests (P16); S5 |
| T-17 | Rounding accumulation | Thousands of operations each rounding the protocol's way, or the user's | Slow leak; broken supply identity | Medium without care | Every division has a specified direction, error carries where it matters, exact cross-multiplication for decisions (ADR-0015, ADR-0017, §8) | Drift is bounded, not zero: `I2` states the bound rather than equality | `I2`, `I8`; Halmos; differential test; `drift.json` |
| T-18 | Interest accrual skipped or double-applied | An operation path that forgets `accrue()`, or accrues twice in one block | Wrong debt, wrong supply, pool depositors mis-credited | Medium | Every state-changing path accrues first; `lastAccrual` makes a second accrual in the same block a no-op; pool functions accrue before touching snapshots (§5.3, §6.2) | A new operation added later could forget; the invariant is the guard | `I2`; `product_sum.json#deposit_after_idle_gets_no_back_interest`; differential test |
| T-19 | Wiring front-run or mis-wiring | Someone calls `wire` before the deployer, or the deployer wires a wrong address | A system pointing at an attacker's contract | Low | `wire` requires `msg.sender == deployer` (immutable) and reverts `AlreadyWired` on a second call; before wiring every state-changing function reverts `NotWired`; the deploy script asserts the cross-contract constraints of §3.3 including constraint 7 (ADR-0021) | A mis-wired deployment is unfixable — it is discarded. Nothing on-chain can check constraint 7 | Wiring tests (P11, P18); deploy-script assertions |
| T-20 | Deployment to the wrong chain | A mistyped RPC URL or a stale environment | A research protocol appearing on a mainnet | Low | Chain-id guard in every broadcast script: 31337, 84532, and 8453 only behind a localhost fork endpoint (ADR-0019) | Human error outside the scripts, e.g. a manual `cast send` | Deploy-script tests (P18); `just smoke` |
| T-21 | Leakage of the testnet signing credential through tooling | Shell history, CI logs, an accidental commit | A testnet account is taken over | Low | Keystore-only signing, no raw key anywhere, pre-tool hooks block the dangerous commands, gitleaks scans diff and working tree on every PR (ADR-0019, P01) | The account has no protocol power at all (no admin roles), so the worst case is a wasted testnet balance | Secret scan in CI; hook tests (P00) |
| T-22 | Dishonest or irreproducible results | Re-tuning after seeing results; hand-edited report numbers; data that cannot be refetched | The report claims something the data do not support | Medium — this is the project's own failure mode | Preregistration frozen before the first sweep, dated addenda only; report numbers only from `experiments/` scripts; raw data reproducible from fetchers and cards; block bootstrap for intervals (ADR-0013, ADR-0020) | A hypothesis contradicted by results must be reported as such; nothing technical prevents a dishonest author | `experiment-auditor` before every results prompt; P30 gate |
| T-23 | Model and contracts silently diverge | A contract change without the matching model change | Sweeps describe a system that was never deployed | Medium | Same-commit rule, zero-tolerance differential test, shared vectors as a third reference (ADR-0012, ADR-0022) | The differential test explores a sampled operation space, not all of it | Differential harness (P23); `spec/vectors/**` on both sides (P10, P22) |
| T-24 | Interest hook failure bricks every operation | Every normal-mode operation — the rescue paths repay, addCollateral and close, liquidation from P20, and `ShutdownModule.check` — runs `_accrue()`, which calls the pool's `onInterest`, the ledger's `onInterest` and `token.mint`. Before P19 a revert in any of them (e.g. the pool's `G` overflow that spec §6.6.3 accepts) made every operation revert, and `check()` with them | Permanent loss of liveness: no repay, no close, no liquidation, no shutdown | Very low, but total and irreversible | **Mitigated at P19 (CHG-006 / ADR-0033):** accrual calls the pool once, under a gas-capped, failure-tolerant assembly call (`POOL_HOOK_GAS = 200_000`); a pool that reverts, panics, runs out of gas or answers malformed has its share redirected to the reserve (`PoolInterestRedirected`). A post-failure floor `ceil(2·POOL_HOOK_GAS/63)` turns a caller-starved call into a revert, so no caller can strip depositors of interest by choosing a gas limit | `SupplyCapExceeded`, reachable only by decades of compounding interest. The gas rule assumes the pool never reverts early when short of gas — the real pool never reads `gasleft()` (spec §6.2). Liquidation and `check` join the failing-pool matrix at P20 / the ShutdownModule prompt | `VaultManagerPoolHookTest` (every failure mode × every accruing operation, real `G` overflow, supply-cap pin, floor ±1, caller-gas sweeps with zero redirections against the real pool and a heavy pool, the gasleft-branching counter-case); `VaultManagerInterestHooksTest.test_F4_revertingPool_isRedirected_normalModeAndWindowBothLive`; `interest.json#accrue_pool_hook_fails` |
| T-25 | Stake collapse in deployment A (P17-1) | Repeated self-liquidations into an empty pool, each followed by redeeming the redistributed debt out of honest positions, shrink the snapshot ratio `totalStakesSnapshot/totalCollateralSnapshot` (§6.5.4) round by round | New positions get stakes of a few wei or zero: redistribution rewards are misallocated, I13's tolerance grows until it is vacuous, and at zero stakes liquidation takes the DEFICIT path of §6.4.1 | Cheap on a young or empty deployment; very expensive on an established one (cost model below) | None in code — accepted by the human 2026-10-26 as documented residual risk. The economic defence is the attacker's loss of about 5–9× the honest collateral once honest positions exist | On a young deployment the attack costs gas only, because penalty and redistributed collateral return to the attacker; this is a testnet with no real value at stake | `scripts/analysis/stake_collapse_cost.py`; `CoreHandlerRegressionsTest.test_regression_I13_derivedBound_stakeCollapse`; I13 (CHG-009) |
| T-26 | Just-in-time liquidation sandwich on the pool (deployment A) | In one transaction: `pool.deposit(X)`, `liquidate(id)`, `pool.withdraw(max)`. The pool lock is released between the calls, so this is not reentrancy; nothing delays a withdrawal after a deposit (§5.3) | The sandwicher takes `X/(T+X)` of the offset's collateral for `X/(T+X)` of the debt, keeping about `X/(T+X) · penalty · dP` that would have gone to standing depositors. Interest is unaffected (`deposit` accrues first) | Medium once liquidation exists (P20); any liquidator can do it | None in code: competition for the penalty is part of what deployment A measures. Raised by the P19 security review (L-2) | Standing depositors' penalty share is diluted by just-in-time capital; the P26 depositor agent and S3 should model it, and the report should state it | `VaultManagerLiquidationTest.test_jitSandwich_measuresProfitAndDilution` (P20: 75 of a 150 penalty captured by matching the standing depositor) |

### T-25 cost model

From `scripts/analysis/stake_collapse_cost.py` (an order-of-magnitude model, not a price; WETH at
$3,000 and Base gas at about 0.01 gwei assumed). Each round opens a position at MCR, liquidates it into
an empty pool and redeems the redistributed debt. "1,000-wei stakes" means a 1-WETH position staked at
about 1,000 wei (about 0.1 % reward misallocation); "zero stakes" means positions up to 100 WETH staked
at 0.

| honest collateral | target | positions opened and liquidated | per position | attacker's net loss |
|---|---|---|---|---|
| none (young deployment) | 1,000-wei stakes | 8 | 73 WETH, reused | gas only (~24 transactions) |
| none (young deployment) | zero stakes | 11 | 73 WETH, reused | gas only (~33 transactions) |
| 33 WETH ($100k) | 1,000-wei / zero stakes | 4,222 / 8,041 | 0.73 WETH | ~$0.61M / ~$1.16M (6× / 12×) |
| 333 WETH ($1M) | 1,000-wei / zero stakes | 41,837 / 79,695 | 0.73 WETH | ~$4.8M / ~$9.1M (4.8× / 9.1×) |
| 3,333 WETH ($10M) | 1,000-wei / zero stakes | 91,991 / 175,233 | 3.3 WETH | ~$47M / ~$89M (4.7× / 8.9×) |

Not modelled, all of which raise the cost: pool deposits that must be burned through first, competing
liquidators, price moves. No code change is planned for P19 or P20.

## 4. Out of scope

What this design does not defend against, stated plainly.

- **Settlement forfeiture.** Settlement is pure pro rata (ADR-0010). A borrower who does not repay
  inside `REPAYMENT_WINDOW` forfeits the surplus collateral of their position to the claim pool —
  an over-collateralised borrower subsidises the other holders. Accepted: settling at the trigger
  price needs a usable price exactly when the oracle may have failed, plus a per-position loop,
  and the A/B comparison does not depend on the rule.
- **Depositor flight.** Nothing stops pool depositors from withdrawing as losses approach (T-07).
  It is measured, not prevented.
- **Full liquidation only.** No close factor in the MVP, so a borrower just below MCR pays the
  penalty on the whole debt (ADR-0023, spec §1.4).
- **An oracle that lies within its bounds.** A plausible but wrong price is acted on. No second
  source, no TWAP cross-check (ADR-0008).
- **Secondary-market peg behaviour.** No model of what the token trades at; the protocol defends a
  floor and a ceiling, not a price (ADR-0001).
- **MEV and ordering.** Base's sequencer orders transactions; the protocol makes no attempt to be
  order-independent except where settlement requires it.
- **Censorship.** If nobody calls `liquidate`, `cover` or `check`, nothing happens. Every such
  function is permissionless, which is the only available defence.
- **Bugs in the contracts.** With no upgrade path, a defect is fixed by redeploying. This is the
  largest residual risk and the reason for the invariant suite, the campaigns and P38.

## 5. Boundaries of the testnet deployment

Blueprint §17.3. The Base Sepolia deployment (P42) is evidence that the contracts deploy, wire and
run end to end on a real L2 — nothing more. It is **not** evidence of economic safety, of
parameter quality, or of behaviour under real liquidity: the testnet has no liquidations worth
making, no arbitrageurs and no oracle stress. Those claims come from the fork experiments
(ADR-0011), and they are claims about Base at the blocks the data cards name.

An unaudited testnet protocol is not ready to hold anyone's funds, and nothing here is offered to
anyone. Issuing a stablecoin to users is regulated — in the EU under MiCA, in the US under state
and federal law. This document is not legal advice; the practical consequence is the one the
project already follows: the token is never offered, the deployment is a demonstration, and the
report says so.
