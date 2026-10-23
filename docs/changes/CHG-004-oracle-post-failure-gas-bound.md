# CHG-004: Double the post-failure gas floor so proxied feeds cannot be starved into a recorded failure; cap it

- Status: **approved 2026-10-23 (option 1) and applied** (spec §3.1, §3.3, §3.4, §6.10.3, D-29;
  24 vector fields), after two checks the human asked for passed: the
  critical cases re-run on Base's real proxy bytecode (fork), and an honest caller with a genuinely
  failing feed tested at the new floor — see "Checks before approval" below. ADR-0030.
- Raised: 2026-10-23, P12 (security-reviewer findings F1, F2; F1 reproduced independently)
- Affects: `docs/spec.md` §3.1 (`ORACLE_POST_FAILURE_GAS` range and start value), §3.3 constraint 4,
  §3.4 (OracleAdapter index 7), §6.10.3 (the argument); ADR-0024's rationale; the
  `ORACLE_POST_FAILURE_GAS` value carried in every system vector's `inputs.params`

## Problem

1. **The gas rule's argument assumes the feed is a single contract** (§6.10.3: "a call that failed
   because the caller supplied too little gas leaves less than `ORACLE_GAS / 63` behind"). Chainlink
   feeds are proxies: `EACAggregatorProxy.latestRoundData()` makes a high-level call into the
   aggregator, which forwards all but 1/64 of *its* gas. When the inner call starves, the proxy
   reverts and **returns the 1/64 it kept**. The adapter then holds its own reserve `q < F/63` plus
   the proxy's leftover `≈ F/64`, about `2F/63` in total, where `F ≤ ORACLE_GAS` is what the
   adapter forwarded. With `ORACLE_POST_FAILURE_GAS = ceil(ORACLE_GAS / 63)`, the spec minimum,
   that can clear the threshold, and if it also covers writing `failureStart` (~22k), a caller has
   forged an oracle failure.
2. **`ORACLE_POST_FAILURE_GAS` has no upper bound.** A value larger than any gas a caller can
   supply makes every genuine failure revert `InsufficientGasForOracle`. `failureStart` then never
   starts and the ORACLE shutdown can never trigger: a silent misconfiguration.

## Evidence

Reproduced against `contracts/src/core/OracleAdapter.sol` as committed at P12, with a proxy of
EACAggregatorProxy's shape (`test/utils/ProxyFeed.sol`) over an honest aggregator that needs `need`
gas, sweeping the caller's gas limit (state reverted after every probe):

| ORACLE_GAS | ORACLE_POST_FAILURE_GAS | need | limits tested | forged recorded failures |
|---|---|---|---|---|
| 1,000,000 | 15,874 (= ceil(1M/63), the spec minimum) | 900,000 | 1,601 (880k–960k, step 50) | **1,601** |
| 1,000,000 | 31,747 (= ceil(2·1M/63)) | 900,000 | 1,601 | 0 |
| 100,000 (start) | 1,588 (start) | 50k–95k | 2,500 | 0 |

The reviewer's scratch project found the same at need 800k and 960k. **At the start parameters the
protocol is safe**: after a starved call the adapter holds at most ~2·100k/63 ≈ 3.2k, far below the
~22k needed to write `failureStart`. The committed test
`OracleAdapterGasTest.test_sweep_proxiedPriceFeedAtTheStartParameters` shows it. The defect needs
`ORACLE_GAS` of roughly 780k or more and an honest feed needing about 76–80 % of it, which is inside
§3.1's range but far from Base's real feeds. With `ORACLE_GAS = 100k`, a starved proxied read can
still return `usable = false` *while `failureStart` is already set* (no write, so harmless here);
ShutdownModule.check must be designed with this in mind (P-shutdown).

A chain of k nested bubbling calls returns at most `F/64 + F/64² + … < F/63`, so the adapter
never holds more than `2·ORACLE_GAS/63` after a starved call, at any proxy depth.

## Checks before approval

1. **Real proxy, not a mock.** The evidence table above came from `ProxyFeed`, a mock of the
   proxy's call shape. Re-run on a Base fork (block 45,198,666) keeping Chainlink's deployed
   `EACAggregatorProxy` (`0x7104…6Bb70`, 9,571 bytes) and replacing only the aggregator behind it by
   an honest but expensive one (`vm.etch`; the real aggregator's cold read costs ~19k and cannot be
   starved at any allowed cap). `OracleGasRuleForkTest`:

   | ORACLE_GAS | max gas left after a starved read | ceil(C/63) | ceil(2C/63) |
   |---|---|---|---|
   | 100,000 | 2,816 | 1,588 — crossed | 3,175 — holds (359 to spare) |
   | 1,000,000 | 28,734 | 15,874 — crossed | 31,747 — holds |

   Adversarial sweep, feed needing 900k at ORACLE_GAS 1M: **789 of 825** limits forged at 15,874,
   **0** at 31,747; start parameters: 0 at 1,588 and 0 at 3,175. Floors of 3,174 and 3,176 behave
   identically at 100k: the measured maximum is 2,816; the number is set by the bound, not tuned.
2. **Honest callers at the new floor** (`test_gasRule_newFloor_*`, floors 1,588 vs 3,175 at a 50k
   cap where both are deployable): a feed that fails by reverting hands back almost all gas — no
   difference; with cold storage (one `fetchPrice` per transaction) no difference either, because
   `fetchPrice`'s own work after a failed read (~4.2k) exceeds both floors. Only a *second*
   `fetchPrice` in the same transaction, with the clock running and a feed that burns its whole cap,
   needs exactly 1,587 more gas; in that band the caller gets `InsufficientGasForOracle` — a
   retryable revert, never a wrong answer.

## Options

1. **Raise the floor to `ceil(2 · ORACLE_GAS / 63)` and add a cap** (recommended).
   - §3.1: `ORACLE_POST_FAILURE_GAS` range `ceil(2·ORACLE_GAS/63) ≤ x ≤ ORACLE_GAS`; start value
     **3,175** (= ceil(200,000/63)).
   - §3.3 constraint 4 and §3.4 index 7 accordingly; OracleAdapter's constructor enforces both ends.
   - §6.10.3 restates the argument with the proxy term: "a starved call leaves the caller less than
     ORACLE_GAS/63 of its own plus less than ORACLE_GAS/63 returned by any chain of bubbling calls
     inside the feed".
   - Consequences: constructor change and tests; the start value changes in every system vector's
     `inputs.params` (a parameter the model never uses: no expected value changes, regenerated
     mechanically); ADR-0024 is superseded by a new ADR stating the corrected bound. Honest
     callers need about 1.6k more gas left after a genuinely failed read, which is negligible.
2. **Guarantee the full cap before each feed call.** Require `gasleft() ≥ ceil(ORACLE_GAS·64/63) +
   overhead` before calling a feed, so the feed always receives `ORACLE_GAS` and starvation is
   impossible whatever its structure; the post-failure check becomes redundant.
   Consequences: every price-reading call needs ~2×102k gas of headroom up front (both feeds), even
   when the feeds are cheap; changes where `InsufficientGasForOracle` fires (spec §6.10.2/§6.10.3)
   and ADR-0024's design. Stronger guarantee, higher cost to every caller.
3. **Keep the spec; assert in the deploy script** (P18) that both real feeds' cold
   `latestRoundData` cost ≤ `ORACLE_GAS / 2`, and add the cap only. Consequences: no code change
   now, but the spec's stated argument stays false and a future deployment with a large
   `ORACLE_GAS` and an expensive feed is unprotected unless the script is remembered.

## Recommendation

Option 1. It makes the spec's argument true for any feed structure at any depth, costs callers
almost nothing, and keeps ADR-0024's design. Option 2 is the most robust but taxes every priced
operation by ~200k gas of required headroom for a configuration the start parameters never reach.
Whatever is chosen, the regression test is the 1M-cap proxied sweep from the evidence table: it
fails today and must pass after.

## Impact

| Area | Impact |
|---|---|
| `docs/spec.md` | §3.1 row and start value, §3.3 constraint 4, §3.4 index 7, §6.10.3 (protected file) |
| `docs/invariants.md` | I12 cites the gas rule; wording check only |
| `spec/vectors/` | `ORACLE_POST_FAILURE_GAS` "1588" → "3175" in every system vector's `inputs.params`; no expected value changes (regenerate, confirm byte-identical otherwise) |
| Solidity | `OracleAdapter` constructor index 7 (both bounds); tests: boundary, 1M proxied sweep |
| Python model | `OracleAdapter.deploy` index 7 |
| Differential | none (gas is not modelled) |
| Deploy script (P18) | uses the new start value; asserts real feeds' cold read gas against `ORACLE_GAS` as a sanity check |
| Experiments, preregistration | none run; `ORACLE_POST_FAILURE_GAS` is not swept |
| ADR | new ADR superseding ADR-0024's bound |
