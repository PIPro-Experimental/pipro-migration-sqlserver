-- ===========================================================================
-- 20_recurring.sql — import the amount-code CATALOGUE and route every
-- legacy employee_amounts value by CODETYPE. Run AFTER 10_employees.sql,
-- ONCE PER TENANT. Nothing is silently dropped.
--
--   settings_employee_amounts (catalogue, ALL codes incl. J) → settings_employee_amounts
--   codetype E → employee_amount_earnings
--   codetype D → employee_amount_deductions
--   codetype C → employee_amount_employer_cost     (cost-to-company; Q-addressed)
--   codetype B → employee_amount_balances          (LIVE working values: leave
--                                                   owed/taken, carry-forwards,
--                                                   basic rate per currency —
--                                                   RAW 4dp, no ×100)
--   codetype T → employee_amount_balances          (IMPORTED AS ZERO — see below)
--   codetype H → employee_amount_deprecated        (IMPORTED AS ZERO — see below)
--     Hours are stale by definition at import time: we import after a run and
--     before new hours are captured/clocked into legacy, so carrying captured
--     values would double or misapply them. The slots come across zeroed.
--     Owner rule: the php system always populates T (decimal) and IGNORES H
--     (HH:mm) — H is legacy-only and phases out on deprecated.
--   codetype Y → migration.ytd_takeon              (mid-year YTD take-on staging
--                                                   → cumulative_ledger, see
--                                                   FOLLOW-UP below)
--   any OTHER recognised codetype (S,J,…)          → employee_amount_deprecated
--                                                    (dead codes; J = unsupported,
--                                                     calc treats as an amount or
--                                                     logs+skips)
--   codetype not found (no catalogue row)          → migration.amount_quarantine
--   employee never loaded (orphan)                 → migration.amount_quarantine
--
-- Values keep their OrdinalNo and stay Q-addressed — no reference rewrite (the
-- physical split is invisible above the loader). employee_amounts is keyed by
-- (EmployeeNo, OrdinalNo); the code name + codetype come from the catalogue,
-- joined on OrdinalNo.
--
-- Runner variables: :legacy_schema :tenant_schema :cutover :system_user_id
--
-- FOLLOW-UP: materialise migration.ytd_takeon → cumulative_ledger/payslip_fact
-- (needs the legacy-Y-code → aggregate-code map + per-period vs opening-balance
-- decision). B codes now land WHOLE in employee_amount_balances (2026-07-23);
-- any per-code refinement (leave→leave_balances, age→drop) is optional, later,
-- and data-driven off the catalogue.
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"tenant_schema", public;

CREATE SCHEMA IF NOT EXISTS migration;
CREATE TABLE IF NOT EXISTS migration.ytd_takeon (
    tenant TEXT NOT NULL, employee_id BIGINT NOT NULL, legacy_empno TEXT NOT NULL,
    code TEXT NOT NULL, amount_minor BIGINT NOT NULL, loaded_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS migration.amount_quarantine (
    tenant TEXT NOT NULL, legacy_empno TEXT NOT NULL, code TEXT, codetype TEXT,
    amount_minor BIGINT, reason TEXT NOT NULL, loaded_at TEXT NOT NULL);

-- ---- CATALOGUE: the unified amount-code definitions (every Q ordinal) --------
INSERT INTO settings_employee_amounts (
    ordinal_no, name, code_type, currency_code, code_limit_minor, tax_type,
    tax_inc_asn, consol_code, adjust_flag, manual_display, prorata, qmf_display)
SELECT
    s.ordinalno, s.description, upper(nullif(s.codetype,'')), s.currency_code,
    (COALESCE(s.codelimit,0)*100)::bigint, s.taxtype, s.taxincasn, s.consolcode,
    s.adjustflag,
    CASE WHEN s.manualdisplayind THEN 1 ELSE 0 END,
    CASE WHEN s.prorataind       THEN 1 ELSE 0 END,
    CASE WHEN s.qmfdisplayind    THEN 1 ELSE 0 END
FROM :"legacy_schema".settings_employee_amounts s
ON CONFLICT (ordinal_no) DO NOTHING;

-- ---- Stage the per-employee amounts (join catalogue on OrdinalNo) -----------
CREATE TEMP TABLE _amt ON COMMIT DROP AS
SELECT
    a.employeeno::text                AS legacy_empno,
    e.user_id                           AS employee_id,      -- pipro link; NULL if employee didn't load
    e.hired_at                          AS hired_at,
    a.ordinalno                       AS ordinal_no,       -- the Q-bank address (preserved)
    s.description                     AS name,             -- code name
    (a.amount_q * 100)::bigint        AS amount_minor,     -- ×100 major→minor
    a.amount_q                        AS amount_raw,       -- full 4dp (balances route)
    upper(nullif(s.codetype, ''))     AS codetype
FROM :"legacy_schema".employee_amounts a
LEFT JOIN :"legacy_schema".settings_employee_amounts s ON s.ordinalno = a.ordinalno
LEFT JOIN employees e ON e.id = 'emp-' || a.employeeno::text
WHERE a.amount_q <> 0;

-- E → earnings.  CHOOSE: label/payroll_code scheme (using catalogue name here).
INSERT INTO employee_amount_earnings (
    id, employee_id, label, amount_minor, taxable, uif_applicable,
    effective_from, recorded_at, created_by_user_id, ended_at, payroll_code)
SELECT
    COALESCE((SELECT max(id) FROM employee_amount_earnings),0) + row_number() OVER (ORDER BY employee_id, ordinal_no),
    employee_id, name, amount_minor, 1, 1,     -- CHOOSE: taxable / uif from catalogue
    hired_at, :'cutover', :system_user_id, NULL, name
FROM _amt WHERE employee_id IS NOT NULL AND codetype = 'E';

-- D → deductions.
INSERT INTO employee_amount_deductions (
    id, employee_id, label, amount_minor, reduces_taxable,
    effective_from, recorded_at, created_by_user_id, ended_at, payroll_code)
SELECT
    COALESCE((SELECT max(id) FROM employee_amount_deductions),0) + row_number() OVER (ORDER BY employee_id, ordinal_no),
    employee_id, name, amount_minor, 0,        -- CHOOSE: reduces_taxable from catalogue
    hired_at, :'cutover', :system_user_id, NULL, name
FROM _amt WHERE employee_id IS NOT NULL AND codetype = 'D';

-- C → employer cost (Q-addressed by ordinal).
INSERT INTO employee_amount_employer_cost (employee_id, ordinal_no, amount_minor)
SELECT employee_id, ordinal_no, amount_minor
FROM _amt WHERE employee_id IS NOT NULL AND codetype = 'C'
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

-- B → balances (LIVE working values; RAW 4dp — rates/day counts, no ×100).
-- Per-code refinement (leave→leave_balances etc.) is a later, data-driven pass.
-- T → balances too, but ZEROED: captured hours are stale post-run (header note).
-- The row still comes across so the slot sheet shows the T slots as present.
INSERT INTO employee_amount_balances (employee_id, ordinal_no, amount)
SELECT employee_id, ordinal_no,
       CASE WHEN codetype = 'T' THEN 0 ELSE amount_raw END
FROM _amt WHERE employee_id IS NOT NULL AND codetype IN ('B', 'T')
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

-- Y → YTD take-on staging (always mid-year; never dropped).
INSERT INTO migration.ytd_takeon (tenant, employee_id, legacy_empno, code, amount_minor, loaded_at)
SELECT :'tenant_schema', employee_id, legacy_empno, name, amount_minor, :'cutover'
FROM _amt WHERE employee_id IS NOT NULL AND codetype = 'Y';

-- Any OTHER recognised codetype (H,S,J,…) → deprecated. H is ZEROED (stale
-- hours, header note) and phases out here — the php system never writes H.
-- ×100 truncation is fine for the rest: J is a DDMMYY int (reverses exactly),
-- S is scratch with no post-run meaning.
INSERT INTO employee_amount_deprecated (employee_id, ordinal_no, amount_minor, codetype)
SELECT employee_id, ordinal_no,
       CASE WHEN codetype = 'H' THEN 0 ELSE amount_minor END, codetype
FROM _amt WHERE employee_id IS NOT NULL AND codetype IS NOT NULL
  AND codetype NOT IN ('E','D','C','Y','B','T')
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

-- Codetype not found (no catalogue row for the ordinal) → quarantine (an error).
INSERT INTO migration.amount_quarantine (tenant, legacy_empno, code, codetype, amount_minor, reason, loaded_at)
SELECT :'tenant_schema', legacy_empno, name, codetype, amount_minor, 'codetype_not_found', :'cutover'
FROM _amt WHERE employee_id IS NOT NULL AND codetype IS NULL;

-- Orphans: amount rows whose employee never loaded → quarantine.
INSERT INTO migration.amount_quarantine (tenant, legacy_empno, code, codetype, amount_minor, reason, loaded_at)
SELECT :'tenant_schema', legacy_empno, name, codetype, amount_minor, 'employee_not_loaded', :'cutover'
FROM _amt WHERE employee_id IS NULL;

COMMIT;
\echo 'Done (catalogue + amounts routed by codetype):' :tenant_schema
