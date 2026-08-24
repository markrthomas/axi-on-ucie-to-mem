Implement the plan in `docs/SWARM_PLAN.md` end-to-end.

1. **Read `docs/SWARM_PLAN.md`** — it is the authoritative requirement/plan for
   this change (Goal, Scope & files, Acceptance, Notes/constraints). Implement
   everything it specifies: write the RTL, testbench, and any other code/edits it
   calls for. This is real feature work — make the full set of changes the plan
   needs, not just minimal fixes.

2. **Verify as you go.** Dispatch dv-env-testers for the environments the change
   affects and iterate until each is green. Respect the plan's constraints and
   the repo conventions; make the smallest change that satisfies the plan.

3. **Gate.** Run the whole gate yourself:
   `make regress VERILATOR="$OSS/bin/verilator" VERILATOR_ROOT="$OSS/share/verilator" VERILATOR_COV="$OSS/bin/verilator_coverage"`.
   It must end `[REGRESS] … PASSED` with coverage ≥ 85%, and meet the plan's
   Acceptance criteria.

4. **Land it.** Only when the whole gate is green: branch `swarm/plan-<short-slug>`
   (never commit on `main`), commit with a clear message + the trailer
   `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`, push, and open a PR
   whose body summarizes what you implemented, how it maps to the plan, and the
   gate result. **A human reviews and merges.** Do NOT edit `docs/SWARM_PLAN.md`.

**Checkpoint continuously.** This may be a long run on a metered/subscription
budget. Branch early, commit + push incrementally, and open a **draft PR** as soon
as you have a coherent partial — keep updating it. If you hit repeated
rate-limit / 429 errors or are otherwise cut off, push what you have and mark the
PR **"PARTIAL — resume needed"** with what's done/left, then stop. Never leave
work only in the working tree.

If the plan is ambiguous, underspecified, or would require a risky/irreversible
change, **stop** and report the blocker (commit what is safe on a branch and open
a draft PR describing what is unresolved) rather than guessing.
