Finalize the containerized AoU DV work.

1. Run and review all eight DV environments of the root `make check` gate
   (cocotb, sv, pack, act, reorder, ooo, mrp, systemc — `sv` covers `make sv`,
   `make vlt` and `make sva-mut`) by dispatching one dv-env-tester each, in
   parallel batches no larger than the HOST CAPACITY line allows.
2. For any environment that fails, make the minimal fix and re-test that env
   until it is green.
3. Have the infra-agent confirm the Docker image builds and the Railway config
   (railway.toml) and entrypoint routing are correct; apply any minimal infra fix.
4. Run the whole gate (`make regress` with the pinned Verilator args and
   `SBY=$OSS/bin/sby` — regress = check + coverage + formal) and confirm
   `[REGRESS] … PASSED` with coverage at or above the 85% floor.
5. If — and only if — the full gate is green, create a branch, commit your
   changes (co-authored trailer), push, and open a PR. A human will merge.
6. Report a concise summary: per-env results, the fixes you made (file:line), the
   gate result, and the PR URL.

Do not push to or commit on main. Make the smallest change that fixes each
problem; if a fix is risky or ambiguous, report it for a human instead of
guessing.
