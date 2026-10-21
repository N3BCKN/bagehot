---
name: spec-change
description: Mandatory procedure when the specification, invariants, an ADR, test vectors or the preregistration appear wrong, incomplete or contradictory. Use as soon as implementation reveals a spec problem — never patch around it.
---
The spec is the contract between the Solidity code, the Python model and the report. Changing it
silently breaks all three.

1. Stop implementing. Do not edit protected files (the hook will block you anyway).
2. Create `docs/changes/CHG-<next number>-<slug>.md` with:
   - Problem: what is wrong, with exact references (file, section, line)
   - Evidence: failing test, counterexample, worked numeric example
   - Options (at least two) with consequences
   - Recommendation
   - Impact: spec sections, invariants, vectors, Solidity, Python model, differential rules,
     experiments already run, preregistration
3. Ask the human to review. Wait.
4. After approval (the human unlocks the files):
   a. write a new ADR referencing the CHG file;
   b. update spec, invariants and vectors;
   c. update tests first, then Solidity, then the Python model;
   d. run `/verify`, `just diff-long` and the invariant campaign;
   e. note the change in `docs/progress.md`; if experiments ran before, list which must be re-run;
   f. remind the human to re-protect the files.
