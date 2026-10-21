---
name: diff-mismatch
description: Triage a mismatch between the Python protocol model and the Solidity contracts reported by the differential test. Use whenever the differential test fails.
---
Both implementations use identical integer arithmetic, so tolerance is zero: any difference is a bug.

1. Take Hypothesis's shrunk sequence and seed. Replay it step by step with snapshots printed after
   each step on both sides (`uv run pytest differential -k <test> -s --hypothesis-seed=<seed>`).
2. Find the first operation where any field diverges. Check, in this order:
   - rounding direction of each division (spec rounding table);
   - order of operations (accrue → apply pending redistribution → act → reinsert);
   - time: block.timestamp on chain vs model time (the harness must set
     `evm_setNextBlockTimestamp` before every transaction);
   - epoch/scale transitions in the stability pool and error-correction carries;
   - tie-breaking in the sorted list;
   - revert parity: same custom error name on both sides.
3. Decide which side matches the spec. If neither, use `/spec-change`.
4. Fix that side and add the sequence as a permanent `@example(...)` or a vector in
   `spec/vectors/` (vectors need human approval when protected).
5. Rerun `just diff-quick`, then `just diff-long`.
