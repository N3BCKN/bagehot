---
name: verify
description: Run the Bagehot pre-commit checks (format, build, tests, Python tests, differential smoke test, static analysis triage). Use before every commit and whenever asked to verify, check or validate the work.
---
Run these in order and stop at the first failure:

1. `just fmt-check`
2. `just build`
3. `just test`
4. `just py-test`
5. `just diff-quick` — only once `differential/` exists
6. `just static` — only once contracts exist. Compare findings with
   `docs/static-analysis-triage.md`. Every new finding must be fixed or added there with a
   justification the human can review. Never suppress a detector globally.
7. `just gas` — only once a gas snapshot exists. An unexpected change needs an explanation.

Report a table: step, result, notes. On failure: diagnose, propose a fix, do not commit.
Never edit tests, invariants, vectors or the triage file merely to turn a check green.
