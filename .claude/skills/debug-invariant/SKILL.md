---
name: debug-invariant
description: Triage a failing Foundry invariant, Medusa property, Halmos counterexample or fuzz failure. Use whenever any invariant or fuzz test fails.
---
1. Reproduce deterministically: rerun with the same seed (`--fuzz-seed`), capture the full call
   sequence and the failing invariant's values.
2. Minimise: turn the sequence into a concrete unit test `test_regression_<invariant>_<short>()`
   in `test/unit/regressions/`. It must fail before the fix.
3. Classify the cause:
   - Code bug → fix the code (and the model).
   - Spec gap → stop and use `/spec-change`.
   - Harness bug (an action the protocol can never see, e.g. a price path the oracle adapter
     would reject) → fix the handler only if the spec proves the input impossible; cite the
     spec section in a comment. Never narrow bounds just to make the failure disappear.
   - Tolerance question → never widen a tolerance without a written bound derivation approved
     through `/spec-change`.
4. Fix, confirm the regression test passes, rerun the whole campaign with a fresh seed and the
   nightly profile.
5. Record in `docs/progress.md`: invariant, root cause, fix, regression test name.
