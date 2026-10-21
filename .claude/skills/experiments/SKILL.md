---
name: experiments
description: Rules for simulations, sweeps, calibration and report generation — preregistration discipline, seeds, provenance, results schema. Use whenever editing experiments/ or reports/, or running sweeps.
user-invocable: false
paths: "experiments/**, reports/**"
---
- Before `docs/preregistration.md` is frozen (P30), only pilot runs on S1 for runtime estimation
  are allowed, and they are labelled `pilot` in results. After the freeze, the analysis follows
  the preregistration exactly; deviations go into a dated addendum before results are looked at.
- Never re-run with different parameters because a result is disappointing. Report it.
- Configs are YAML validated by a schema (pydantic). The config hash (sha256 of canonical JSON)
  identifies a run family.
- Every result row carries: config hash, scenario, variant (A/B), run index, seed, git commit,
  data card checksums, environment (model / fork_replay / fork_historical), wall time.
- Results are Parquet under `experiments/results/<scenario>/<config_hash>/`, partitioned; runs are
  resumable and never overwritten — a new commit means new rows.
- Statistics: report medians with bootstrap 95% intervals; state the number of runs; show
  distributions, not only means.
- Figures and tables are produced only by `experiments/report.py`; every figure file name encodes
  scenario and config hash; captions state assumptions.
- Use the `experiment-auditor` subagent before declaring any results prompt done.
