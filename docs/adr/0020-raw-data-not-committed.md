# ADR-0020: Keep raw data out of the repository; make it reproducible from fetchers and cards

- Status: proposed
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §13. The study pulls price history, oracle rounds, liquidation events, gas and liquidity
snapshots from Base. That is a large body of data that would bloat the repository, go stale, and —
for API-sourced series — may carry licence conditions that forbid redistribution.

Reproducibility does not require shipping the bytes. It requires that anyone can obtain the same
bytes and verify they got the same ones.

## Decision

`data/raw/` and `data/processed/` are git-ignored. Every data set has a fetcher in `data/` and a
**data card** in `data/cards/` (committed) recording the source, the endpoint, the exact query
window, block range or aggregator phase, the retrieval date, row counts, checksums and the
licence. `data/validate.py` checks a fetched set against its card. Report numbers come only from
scripts in `experiments/` (`CLAUDE.md`), so no number in `reports/` can exist without a path back
to a card.

## Alternatives considered

- **Commit the raw data.** Repository size, licence exposure, and a false sense of
  reproducibility — a committed CSV with no provenance is not more reproducible than a card.
- **Commit processed data only.** Hides the transformation step, which is where most errors live.

## Consequences

- A fresh clone cannot reproduce the report without network access and an archive RPC; the README
  says so.
- Checksums in the cards catch a silently changed upstream data set.
- CI jobs that need data take it from an uploaded artefact, never from a scheduled refetch.
