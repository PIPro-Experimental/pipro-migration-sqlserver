-- ===========================================================================
-- 20_recurring.sql — route ALL of legacy employee_amounts by CODETYPE.
-- Run AFTER 10_employees.sql, ONCE PER TENANT. Nothing is silently dropped.
--
--   codetype E → employee_recurring_earnings
--   codetype D → employee_recurring_deductions
--   codetype Y → migration.ytd_takeon        (mid-year YTD take-on staging)
--   anything else (J,H,B,C,I,S, unknown, or codetype not found) → migration.amount_quarantine
--   amount whose employee never loaded (orphan)                 → migration.amount_quarantine
--
-- codetype comes from the interim settings_employee_amounts table (or legacy
-- pw_parm_codes). Amounts are always treated as MID-YEAR, so Y is taken on, never
-- dropped.
--
-- Runner variables: :legacy_schema :tenant_schema :cutover :system_user_id
--
-- FOLLOW-UP (not done here): materialise migration.ytd_takeon into
-- cumulative_ledger / payslip_fact. That needs (1) a legacy-Y-code → pipro
-- aggregate-code map (TAXABLE / PAYE / RF_DEDUCTIBLE) and (2) a per-period vs
-- single-opening-balance decision — the latter only affects tax_method='cumulative'
-- payrolls, whose engine divisor counts prior periods (see PayslipFactWriter/YtdFactReader).
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"tenant_schema", public;

-- Persistent report/staging tables — shared across tenants; inspect AFTER the run
-- to answer "what are B/C/I/S, and how much rides on each?".
CREATE SCHEMA IF NOT EXISTS migration;
CREATE TABLE IF NOT EXISTS migration.ytd_takeon (
    tenant TEXT NOT NULL, employee_id BIGINT NOT NULL, legacy_empno TEXT NOT NULL,
    code TEXT NOT NULL, amount_minor BIGINT NOT NULL, loaded_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS migration.amount_quarantine (
    tenant TEXT NOT NULL, legacy_empno TEXT NOT NULL, code TEXT, codetype TEXT,
    amount_minor BIGINT, reason TEXT NOT NULL, loaded_at TEXT NOT NULL);

-- Stage source amounts, resolving codetype + the pipro employee link.
CREATE TEMP TABLE _amt ON COMMIT DROP AS
SELECT
    a."EmployeeNo"::text                AS legacy_empno,
    e.user_id                           AS employee_id,     -- pipro link; NULL if the employee didn't load
    e.hired_at                          AS hired_at,
    a."Code"                            AS code,
    a."Description"                     AS label,           -- CONFIRM: label source
    (a.amount * 100)::bigint            AS amount_minor,    -- CONFIRM: ×100 if major units
    upper(nullif(s."codetype", ''))     AS codetype         -- CONFIRM: settings_employee_amounts.codetype
FROM :"legacy_schema".employee_amounts a
LEFT JOIN :"legacy_schema".settings_employee_amounts s      -- CONFIRM: code-definition table + join key
       ON s."Code" = a."Code"
LEFT JOIN employees e ON e.id = 'emp-' || a."EmployeeNo"::text
WHERE a.amount <> 0;

-- E → earnings (employee loaded, codetype E).
INSERT INTO employee_recurring_earnings (
    id, employee_id, label, amount_minor, taxable, uif_applicable,
    effective_from, recorded_at, created_by_user_id, ended_at, payroll_code)
SELECT
    COALESCE((SELECT max(id) FROM employee_recurring_earnings),0) + row_number() OVER (ORDER BY employee_id, code),
    employee_id, label, amount_minor,
    1, 1,                                      -- CHOOSE: taxable / uif flags (from settings_employee_amounts)
    hired_at, :'cutover', :system_user_id, NULL, code
FROM _amt WHERE employee_id IS NOT NULL AND codetype = 'E';

-- D → deductions.
INSERT INTO employee_recurring_deductions (
    id, employee_id, label, amount_minor, reduces_taxable,
    effective_from, recorded_at, created_by_user_id, ended_at, payroll_code)
SELECT
    COALESCE((SELECT max(id) FROM employee_recurring_deductions),0) + row_number() OVER (ORDER BY employee_id, code),
    employee_id, label, amount_minor,
    0,                                         -- CHOOSE: reduces_taxable (pre-tax) from settings
    hired_at, :'cutover', :system_user_id, NULL, code
FROM _amt WHERE employee_id IS NOT NULL AND codetype = 'D';

-- Y → YTD take-on staging (always mid-year; never dropped).
INSERT INTO migration.ytd_takeon (tenant, employee_id, legacy_empno, code, amount_minor, loaded_at)
SELECT :'tenant_schema', employee_id, legacy_empno, code, amount_minor, :'cutover'
FROM _amt WHERE employee_id IS NOT NULL AND codetype = 'Y';

-- Anything else with a loaded employee → quarantine (codetype not E/D/Y, or unknown).
INSERT INTO migration.amount_quarantine (tenant, legacy_empno, code, codetype, amount_minor, reason, loaded_at)
SELECT :'tenant_schema', legacy_empno, code, codetype, amount_minor,
       CASE WHEN codetype IS NULL THEN 'codetype_not_found' ELSE 'codetype_not_EDY' END, :'cutover'
FROM _amt WHERE employee_id IS NOT NULL AND (codetype IS NULL OR codetype NOT IN ('E','D','Y'));

-- Orphans: amount rows whose employee never loaded → quarantine.
INSERT INTO migration.amount_quarantine (tenant, legacy_empno, code, codetype, amount_minor, reason, loaded_at)
SELECT :'tenant_schema', legacy_empno, code, codetype, amount_minor, 'employee_not_loaded', :'cutover'
FROM _amt WHERE employee_id IS NULL;

COMMIT;
\echo 'Done (amounts routed by codetype):' :tenant_schema
