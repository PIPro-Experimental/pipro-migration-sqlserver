-- ===========================================================================
-- 91_employee_snapshot.sql — capture ONE phase of ONE system's employee-table
-- values into a canonical long-form shape, so any two captures can be diffed.
--
-- Runner variables:
--   :system   interim | pipro        (legacy lands via the sqlcmd export)
--   :phase    before  | after        (relative to the pay run)
--   :snap     a unique label, e.g. 'pipro-before-2026-09'
--   :legacy_company_schema :tenant_schema
--
-- WHY SNAPSHOTS AND NOT VIEWS
-- ---------------------------
-- The report has to show both the BEFORE-run and AFTER-run state. A run
-- overwrites the before-state in place, so the before-state cannot be
-- recovered later by any query — it must be captured first. THIS IS THE ONE
-- STEP THAT CANNOT BE REDONE: capture every system's `before` snapshot BEFORE
-- running payroll anywhere.
--
-- THE CANONICAL SHAPE is (employee_code, bank, ordinal_no, value) — the legacy
-- ordinal-bank addressing, which is the only vocabulary all three systems
-- share. Banks:
--   Q  amounts     pw_amts    -> interim employee_amounts -> 5 pipro tables
--   V  alpha       pw_inds + pw_refnos (refnos carry +100) -> employee_alpha
--   D  dates       pw_dates   -> employee_dates
--
-- Employee identity is resolved through compare.employee_map (90) — never
-- through 'emp-' || <legacy EmpNo>, which is the surrogate trap documented
-- there. Run 90 for this tenant first.
--
-- MONEY is normalised to MAJOR units (NUMERIC, as the legacy MONEY column
-- holds) on the way in, so a diff never compares minor against major. pipro
-- stores E/D/C/deprecated/ytd as *_minor BIGINT (/100 here) but balances as a
-- raw 4dp NUMERIC (carried as-is) — see 20_recurring.
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE SCHEMA IF NOT EXISTS compare;

CREATE TABLE IF NOT EXISTS compare.snapshot (
    snap          TEXT PRIMARY KEY,
    system        TEXT NOT NULL CHECK (system IN ('legacy','interim','pipro')),
    phase         TEXT NOT NULL CHECK (phase  IN ('before','after')),
    tenant_schema TEXT,
    source_schema TEXT,
    taken_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS compare.employee_value (
    snap          TEXT    NOT NULL REFERENCES compare.snapshot(snap) ON DELETE CASCADE,
    employee_code TEXT    NOT NULL,
    bank          CHAR(1) NOT NULL CHECK (bank IN ('Q','V','D')),
    ordinal_no    INTEGER NOT NULL,
    value_num     NUMERIC,            -- Q: major units. NULL for V/D.
    value_text    TEXT,               -- V: reference. D: ISO date. NULL for Q.
    origin        TEXT NOT NULL,      -- physical table it came from (diagnosis)
    PRIMARY KEY (snap, employee_code, bank, ordinal_no)
);

-- Values whose ordinal could not be recovered — E/D rows in pipro are stored
-- label-addressed, and 4 catalogue names are duplicated, so those labels do not
-- resolve to one ordinal. Parked here rather than guessed at.
CREATE TABLE IF NOT EXISTS compare.employee_value_unmapped (
    snap          TEXT NOT NULL REFERENCES compare.snapshot(snap) ON DELETE CASCADE,
    employee_code TEXT,
    label         TEXT,
    value_num     NUMERIC,
    origin        TEXT NOT NULL,
    reason        TEXT NOT NULL
);

-- Idempotent: re-capturing a label replaces it.
DELETE FROM compare.snapshot WHERE snap = :'snap';
INSERT INTO compare.snapshot (snap, system, phase, tenant_schema, source_schema)
VALUES (:'snap', :'system', :'phase', :'tenant_schema', :'legacy_company_schema');

-- ---------------------------------------------------------------------------
-- INTERIM — the desktop iteration-2 copy. Child rows key on the interim
-- surrogate, so employee_code comes off the interim employees table — qualified
-- by payroll ("<payroll>/<EmpNo>"), because the bare EmpNo is unique only within
-- a payroll database while pipro's employee_code is unique across the tenant.
-- ---------------------------------------------------------------------------
INSERT INTO compare.employee_value (snap, employee_code, bank, ordinal_no, value_num, origin)
SELECT :'snap', btrim(e.payroll_f04::text || '/' || e.employeeid_f01), 'Q', a.ordinalno, a.amount_q, 'employee_amounts'
FROM :"legacy_company_schema".employee_amounts a
JOIN :"legacy_company_schema".employees e ON e.employeeno = a.employeeno
WHERE :'system' = 'interim'
ON CONFLICT DO NOTHING;

INSERT INTO compare.employee_value (snap, employee_code, bank, ordinal_no, value_text, origin)
SELECT :'snap', btrim(e.payroll_f04::text || '/' || e.employeeid_f01), 'V', v.ordinalno, v.reference_v, 'employee_alpha'
FROM :"legacy_company_schema".employee_alpha v
JOIN :"legacy_company_schema".employees e ON e.employeeno = v.employeeno
WHERE :'system' = 'interim'
ON CONFLICT DO NOTHING;

INSERT INTO compare.employee_value (snap, employee_code, bank, ordinal_no, value_text, origin)
SELECT :'snap', btrim(e.payroll_f04::text || '/' || e.employeeid_f01), 'D', d.ordinalno, d.date_d0::text, 'employee_dates'
FROM :"legacy_company_schema".employee_dates d
JOIN :"legacy_company_schema".employees e ON e.employeeno = d.employeeno
WHERE :'system' = 'interim'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- PIPRO — the Q bank is reassembled from the five tables 20_recurring fanned it
-- out to, plus the ytd_takeon staging. Identity via compare.employee_map.
-- ---------------------------------------------------------------------------
INSERT INTO compare.employee_value (snap, employee_code, bank, ordinal_no, value_num, origin)
SELECT :'snap', m.employee_code, 'Q', src.ordinal_no, src.value_num, src.origin
FROM (
    -- C: ordinal-addressed, minor units
    SELECT employee_id, ordinal_no, amount_minor::numeric / 100 AS value_num,
           'employee_amount_employer_cost' AS origin
      FROM :"tenant_schema".employee_amount_employer_cost
    UNION ALL
    -- B/T: ordinal-addressed, RAW 4dp (no /100 — see 20_recurring)
    SELECT employee_id, ordinal_no, amount, 'employee_amount_balances'
      FROM :"tenant_schema".employee_amount_balances
    UNION ALL
    -- H/S/J: ordinal-addressed, minor units
    SELECT employee_id, ordinal_no, amount_minor::numeric / 100, 'employee_amount_deprecated'
      FROM :"tenant_schema".employee_amount_deprecated
    UNION ALL
    -- E: label-addressed + bitemporal; current rows only, ordinal recovered
    SELECT x.employee_id, c.ordinal_no, x.amount_minor::numeric / 100, 'employee_amount_earnings'
      FROM :"tenant_schema".employee_amount_earnings x
      JOIN :"tenant_schema".settings_employee_amounts c ON c.name = x.label
     WHERE x.ended_at IS NULL
       AND (SELECT count(*) FROM :"tenant_schema".settings_employee_amounts d WHERE d.name = x.label) = 1
    UNION ALL
    -- D: same
    SELECT x.employee_id, c.ordinal_no, x.amount_minor::numeric / 100, 'employee_amount_deductions'
      FROM :"tenant_schema".employee_amount_deductions x
      JOIN :"tenant_schema".settings_employee_amounts c ON c.name = x.label
     WHERE x.ended_at IS NULL
       AND (SELECT count(*) FROM :"tenant_schema".settings_employee_amounts d WHERE d.name = x.label) = 1
    UNION ALL
    -- Y: still in migration staging until ytd_takeon is materialised
    SELECT y.employee_id, c.ordinal_no, y.amount_minor::numeric / 100, 'migration.ytd_takeon'
      FROM migration.ytd_takeon y
      JOIN :"tenant_schema".settings_employee_amounts c ON c.name = y.code
     WHERE y.tenant = :'tenant_schema'
       AND (SELECT count(*) FROM :"tenant_schema".settings_employee_amounts d WHERE d.name = y.code) = 1
) src
JOIN compare.employee_map m
  ON m.tenant_schema = :'tenant_schema' AND m.pipro_user_id = src.employee_id
WHERE :'system' = 'pipro'
ON CONFLICT DO NOTHING;

INSERT INTO compare.employee_value (snap, employee_code, bank, ordinal_no, value_text, origin)
SELECT :'snap', m.employee_code, 'V', v.ordinal_no, v.value, 'employee_alpha'
FROM :"tenant_schema".employee_alpha v
JOIN compare.employee_map m
  ON m.tenant_schema = :'tenant_schema' AND m.pipro_user_id = v.employee_id
WHERE :'system' = 'pipro'
ON CONFLICT DO NOTHING;

INSERT INTO compare.employee_value (snap, employee_code, bank, ordinal_no, value_text, origin)
SELECT :'snap', m.employee_code, 'D', d.ordinal_no, d.value, 'employee_dates'
FROM :"tenant_schema".employee_dates d
JOIN compare.employee_map m
  ON m.tenant_schema = :'tenant_schema' AND m.pipro_user_id = d.employee_id
WHERE :'system' = 'pipro'
ON CONFLICT DO NOTHING;

-- Park the E/D rows whose label does not resolve to exactly one ordinal.
INSERT INTO compare.employee_value_unmapped (snap, employee_code, label, value_num, origin, reason)
SELECT :'snap', m.employee_code, x.label, x.amount_minor::numeric / 100, x.origin,
       'label matches ' || (SELECT count(*) FROM :"tenant_schema".settings_employee_amounts d
                             WHERE d.name = x.label)::text || ' catalogue ordinals'
FROM (
    SELECT employee_id, label, amount_minor, 'employee_amount_earnings' AS origin
      FROM :"tenant_schema".employee_amount_earnings WHERE ended_at IS NULL
    UNION ALL
    SELECT employee_id, label, amount_minor, 'employee_amount_deductions'
      FROM :"tenant_schema".employee_amount_deductions WHERE ended_at IS NULL
) x
JOIN compare.employee_map m
  ON m.tenant_schema = :'tenant_schema' AND m.pipro_user_id = x.employee_id
WHERE :'system' = 'pipro'
  AND (SELECT count(*) FROM :"tenant_schema".settings_employee_amounts d WHERE d.name = x.label) <> 1;

COMMIT;

\echo ''
\echo '=== Snapshot captured ====================================================='
SELECT s.snap, s.system, s.phase, s.taken_at,
       (SELECT count(*) FROM compare.employee_value v WHERE v.snap = s.snap) AS values,
       (SELECT count(*) FROM compare.employee_value_unmapped u WHERE u.snap = s.snap) AS unmapped
FROM compare.snapshot s WHERE s.snap = :'snap';

\echo ''
\echo '=== Rows per bank / origin ================================================'
SELECT bank, origin, count(*) AS rows, count(DISTINCT employee_code) AS employees
FROM compare.employee_value WHERE snap = :'snap'
GROUP BY bank, origin ORDER BY bank, origin;

\echo ''
\echo '=== Unmapped (label did not resolve to one ordinal) ======================='
SELECT label, origin, reason, count(*) AS rows
FROM compare.employee_value_unmapped WHERE snap = :'snap'
GROUP BY label, origin, reason ORDER BY count(*) DESC;
