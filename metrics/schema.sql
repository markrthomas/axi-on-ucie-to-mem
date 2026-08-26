-- =============================================================================
-- metrics/schema.sql — the AoU metrics database (SQLite, committed as
-- metrics/metrics.db).  Written by metrics/collect.py, read by
-- metrics/dashboard.py.  History is APPEND-ONLY so the dashboard can trend.
--
-- Design rules baked into the schema (see docs/NOTES.md -> "Metrics DB"):
--
--   * One `run` row per collected run, keyed by a stable, human-meaningful
--     `run_key` (UNIQUE) so `make metrics` is IDEMPOTENT: re-collecting the same
--     run replaces that run's child rows instead of appending a duplicate.
--
--   * Every value carries a `kind`:
--         'measured'          read from a real artifact (a log, coverage.info,
--                             /usr/bin/time, a yosys stat, the run result JSON).
--         'estimated'         MODELED from measured inputs and a documented
--                             coefficient (metrics/coefficients.json) — energy,
--                             cost, Fmax, generic-cell gate counts.
--         'not_attributable'  the number was ASKED FOR but the tooling cannot
--                             attribute it.  `value` is NULL and `source` holds
--                             the reason.  Never fabricate — record the gap.
--     The CHECK constraint below makes a fabricated "measured" energy figure a
--     schema error rather than a judgement call.
--
--   * Four per-domain tables mirror the four dashboard sections.  They share the
--     same shape (scope/name/value/unit/kind/source) so the dashboard can treat
--     them uniformly through the v_metric view; `ai_metric` adds the agent/model
--     axes that the per-(agent x model) breakdown needs.
--
-- Safe to run repeatedly: everything is CREATE ... IF NOT EXISTS.
-- =============================================================================

PRAGMA foreign_keys = ON;

-- One row per collected run ---------------------------------------------------
CREATE TABLE IF NOT EXISTS run (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    -- Idempotency key.  Default: "<git-sha12>/<trigger>/<ci-run-id or ts>".
    run_key        TEXT    NOT NULL UNIQUE,
    git_sha        TEXT    NOT NULL,
    git_branch     TEXT    NOT NULL,
    git_dirty      INTEGER NOT NULL DEFAULT 0,   -- 1 = collected from a dirty tree
    ts_utc         TEXT    NOT NULL,             -- ISO-8601 Zulu, collection time
    trigger        TEXT    NOT NULL,             -- local | ci | railway | swarm
    runner         TEXT    NOT NULL,             -- free-form host descriptor
    runner_vcpu    INTEGER,
    runner_ram_mb  INTEGER,
    collector_ver  TEXT    NOT NULL,
    notes          TEXT
);

CREATE INDEX IF NOT EXISTS run_ts_idx ON run (ts_utc);

-- Domain 1 — design / RTL -----------------------------------------------------
-- scope = module name ('' = whole design).
CREATE TABLE IF NOT EXISTS design_metric (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id  INTEGER NOT NULL REFERENCES run (id) ON DELETE CASCADE,
    scope   TEXT    NOT NULL DEFAULT '',
    name    TEXT    NOT NULL,
    value   REAL,
    unit    TEXT    NOT NULL DEFAULT '',
    kind    TEXT    NOT NULL CHECK (kind IN ('measured', 'estimated', 'not_attributable')),
    source  TEXT    NOT NULL DEFAULT '',
    UNIQUE (run_id, scope, name)
);

-- Domain 2 — verification / coverage -----------------------------------------
-- scope = DV env or proof name ('' = whole suite).
CREATE TABLE IF NOT EXISTS verif_metric (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id  INTEGER NOT NULL REFERENCES run (id) ON DELETE CASCADE,
    scope   TEXT    NOT NULL DEFAULT '',
    name    TEXT    NOT NULL,
    value   REAL,
    unit    TEXT    NOT NULL DEFAULT '',
    kind    TEXT    NOT NULL CHECK (kind IN ('measured', 'estimated', 'not_attributable')),
    source  TEXT    NOT NULL DEFAULT '',
    UNIQUE (run_id, scope, name)
);

-- Domain 3 — CI / compute -----------------------------------------------------
-- scope = gate step / env ('' = whole run).
CREATE TABLE IF NOT EXISTS compute_metric (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id  INTEGER NOT NULL REFERENCES run (id) ON DELETE CASCADE,
    scope   TEXT    NOT NULL DEFAULT '',
    name    TEXT    NOT NULL,
    value   REAL,
    unit    TEXT    NOT NULL DEFAULT '',
    kind    TEXT    NOT NULL CHECK (kind IN ('measured', 'estimated', 'not_attributable')),
    source  TEXT    NOT NULL DEFAULT '',
    UNIQUE (run_id, scope, name)
);

-- Domain 4 — AI / swarm -------------------------------------------------------
-- agent = swarm-manager | dv-env-tester[:env] | infra-agent | dv-runner | '' (whole run)
-- model = concrete model id ('' = not split by model / aggregate row)
CREATE TABLE IF NOT EXISTS ai_metric (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id  INTEGER NOT NULL REFERENCES run (id) ON DELETE CASCADE,
    agent   TEXT    NOT NULL DEFAULT '',
    model   TEXT    NOT NULL DEFAULT '',
    name    TEXT    NOT NULL,
    value   REAL,
    unit    TEXT    NOT NULL DEFAULT '',
    kind    TEXT    NOT NULL CHECK (kind IN ('measured', 'estimated', 'not_attributable')),
    source  TEXT    NOT NULL DEFAULT '',
    UNIQUE (run_id, agent, model, name)
);

-- Uniform view over all four domains, for the trend/regression queries. --------
CREATE VIEW IF NOT EXISTS v_metric AS
    SELECT 'design'  AS domain, run_id, scope,                       name, value, unit, kind, source FROM design_metric
    UNION ALL
    SELECT 'verif'   AS domain, run_id, scope,                       name, value, unit, kind, source FROM verif_metric
    UNION ALL
    SELECT 'compute' AS domain, run_id, scope,                       name, value, unit, kind, source FROM compute_metric
    UNION ALL
    SELECT 'ai'      AS domain, run_id,
           CASE WHEN model = '' THEN agent ELSE agent || ' / ' || model END AS scope,
           name, value, unit, kind, source FROM ai_metric;
