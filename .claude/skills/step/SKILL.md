---
name: step
description: Execute one numbered build prompt from prompts/ (for example /step 14). Only when the user invokes it.
disable-model-invocation: true
argument-hint: "[prompt number, e.g. 14]"
---
Execute build prompt number $ARGUMENTS of the Bagehot plan.

1. Zero-pad the number to two digits and open the single file matching `prompts/P<NN>-*.md`.
   If none or more than one file matches, stop and ask.
2. Read `CLAUDE.md`, `docs/progress.md`, then every file in the prompt's "Read first" list.
3. Check "Depends on": each listed prompt must be `done` in `docs/progress.md`. If not, stop and
   report what is missing. Never silently do a dependency's work.
4. Mark the prompt `in progress` in `docs/progress.md`.
5. Restate the goal, deliverables and acceptance criteria in at most six bullets.
6. If the prompt says "Mode: plan first", present a concrete plan (files, order, test strategy,
   risks) and wait for approval. Otherwise proceed.
7. Execute following the Session protocol in `CLAUDE.md`: tests first, narrow loops, small commits.
8. Before finishing: run `/verify`, invoke any reviewer subagent the prompt requires, check every
   acceptance criterion explicitly (state the command and its result), update `docs/progress.md`
   (status, commit, notes, open issues, human actions), and propose the commit message.
9. If an acceptance criterion cannot be met, mark the prompt `blocked`, explain why, and stop.
