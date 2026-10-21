# Gas

> **Stub — baseline established at P37.** `just gas` guards itself until
> `contracts/.gas-snapshot` exists; create the first one with `just gas-update`.

Gas matters here as an input to the research question, not as an optimisation target for its own
sake: liquidation cost sets the floor on what a liquidator will accept, and that floor differs
between the stability pool (A) and the Dutch auction (B). A gas regression therefore changes a
reported number, which is why `just gas` is part of `/verify`.

## Method

<!-- Which operations are measured, at what state, with which profile. Snapshots come from
     `forge snapshot`; the cost model that turns gas into USD lives in model/costs.py (P24). -->

## Baseline

| Operation | Gas | Snapshot date | Commit |
|---|---|---|---|

## Changes

<!-- Every movement in the snapshot, with the reason. An unexplained change blocks a commit. -->

| date | operation | before | after | reason |
|---|---|---|---|---|
