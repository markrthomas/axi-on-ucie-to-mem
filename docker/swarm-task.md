Finalize the containerized AoU DV work.

1. Run and review every DV environment (cocotb, sv, pack, act, reorder, systemc)
   by dispatching one dv-env-tester each, in parallel.
2. For any environment that fails, make the minimal fix and re-test that env
   until it is green.
3. Have the infra-agent confirm the Docker image builds and the Railway config
   (railway.toml) and entrypoint routing are correct; apply any minimal infra fix.
4. Run the whole gate (`make regress` with the pinned Verilator args) and confirm
   `[REGRESS] … PASSED` with coverage at or above the 85% floor.
5. If — and only if — the full gate is green, create a branch, commit your
   changes (co-authored trailer), push, and open a PR. A human will merge.
6. Report a concise summary: per-env results, the fixes you made (file:line), the
   gate result, and the PR URL.

Do not push to or commit on main. Make the smallest change that fixes each
problem; if a fix is risky or ambiguous, report it for a human instead of
guessing.
