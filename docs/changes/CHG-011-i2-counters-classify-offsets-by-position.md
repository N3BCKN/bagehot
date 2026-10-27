# CHG-011: I2's counter table classifies pool offsets by the pool's state; spec §10.2 classifies them by the position

- Status: **approved by the human 2026-10-26** ("aproved, files unlocked, please proceed"; proposed the same day, P20 plan). Code, model and tests applied. **Applied 2026-10-27:** spec/invariant text written.
- Affects: `docs/invariants.md` I2 ("Counter rules": the `gX` and `gY` rows, and one added sentence).
  No spec, contract, model or vector change.

## Problem

Spec §10.2 bounds the drift `E = n·I − (S − A − F)·RAY` by counting each operation's sub-effects
into `X` (each changes `E` by `[0, I)`) or `Y` (each by `[0, RAY)`). For a pool offset it decides by
**the position**:

- *partial pool offset* — the pool absorbs `a < debt`, and `n −= ⌊a·RAY/I⌋` (R34), `S −= a`:
  ΔE = `a·RAY − ⌊a·RAY/I⌋·I` ∈ `[0, I)` → **X**;
- *full pool offset* — the pool absorbs the whole debt, `n −= nᵢ`, `S −= ⌈nᵢ·I/RAY⌉`:
  ΔE ∈ `[0, RAY)` → **Y**.

`docs/invariants.md` I2 decides by **the pool**: `PoolOffset` leaving `totalDeposits > 0` → `gX`,
leaving `totalDeposits == 0` → `gY`. The two coincide only by accident:

| case (§6.4.1, §6.6.4) | pool after | §10.2 | invariants.md today | effect |
|---|---|---|---|---|
| full absorption, `debt < T` | `T − debt > 0` | Y (`[0, RAY)`) | gX (`< I`) | looser: still sound (`I ≥ RAY`) |
| full absorption, `debt == T` | 0 | Y | gY | same |
| partial absorption, `0 < dA = T < debt` | 0 (it emptied) | X (`[0, I)`) | gY (`< RAY`) | **too tight: a correct contract can fail I2** |

**Worked case.** With the index after one hour at the start rate, `I = 1,000,005,569,668,954,547,626,347,955`
(`interest.json#accrue_pool_share`), a partial absorption of `a = 4,000.000000000001244698` stablecoin
(`4000000000000001244698` wei) gives ΔE = `1,000,005,329,941,138,278,823,305,850` = `RAY + 5.33·10²¹`:
inside §10.2's `[0, I)`, outside the `[0, RAY)` the current table grants. With the round index
`1.05·RAY` the worst residue is exactly `RAY`, which already breaks the strict bound when it is the
only count. Before P20 no liquidation existed, so nothing exercised the rule.

## Options

1. **Classify from `Liquidated`, as §10.2 does** (recommended): `0 < debtAbsorbed < debt` → `gX`;
   `debtAbsorbed == debt` (and `> 0`) → `gY`; `debtAbsorbed == 0` → nothing. The event carries both
   fields, so the counter stays event-driven.
2. **Count every pool offset as `gX`** (`[0, I)` covers both cases since `I ≥ RAY`). Sound but
   looser than §10.2 for full absorptions, and the invariant would no longer match the spec's
   derivation — rejected.

## Exact wording (option 1) to apply to `docs/invariants.md` I2

### "Counter rules": replaces the `gX` and `gY` rows

| Counter | Incremented by | Event it is read from |
|---|---|---|
| `gX` | `openPosition`, `borrow`; each partial repay, partial redemption, partial pool offset | `PositionUpdated` with `op ∈ {OP_OPEN, OP_BORROW, OP_REPAY}` only — the same event fires for `addCollateral`, `withdrawCollateral` and `liquidate`, which contribute 0 — plus `PositionRedeemed(closed=false)` and `Liquidated` with `0 < debtAbsorbed < debt` |
| `gY` | `close`; each full redemption; each full pool offset; each auction start; each no-stakes deficit record | `PositionUpdated(OP_CLOSE)`, `PositionRedeemed(closed=true)`, `Liquidated` with `debtAbsorbed == debt` in deployment A, `AuctionStarted`, `DeficitRecorded(source=NO_STAKES)` |

### Added after the table, before "**An offset of zero adds nothing**"

**Partial and full are properties of the position, not of the pool** (§10.2): a pool offset is
*full* when it absorbs the liquidated position's whole debt (`debtAbsorbed == debt`; `n` falls by
`nᵢ`, ΔE ∈ `[0, RAY)`) and *partial* when it absorbs less (`n` falls by `⌊a·RAY/I⌋`, R34, ΔE ∈
`[0, I)`), whatever `totalDeposits` is afterwards. A partial absorption always empties the pool and
a full one usually does not, so keying on `totalDeposits` — as this table did until CHG-011 — counts
the partial case against `RAY` where its error can reach `I > RAY`. In deployment B the house's
`onLiquidation` returns `debtAbsorbed == debt` and the auction start is counted by `AuctionStarted`,
so `Liquidated` is not counted there (one sub-effect, one count).

## Impact

- `docs/invariants.md` I2 only; §10.2 is unchanged (it was right).
- The P20 core handler counts from `Liquidated` per this text (Foundry from events, Medusa from its
  state reconstruction); `model.invariants.check_I2` (when written) the same.
- The "Breaks if" targeted sequence ("partial offset followed immediately by a no-stakes deficit
  (counts 1 to `gX` and 1 to `gY`)") is already consistent with option 1.
- Contract, model, vectors, experiments: none.
