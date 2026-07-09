-- ===========================================================================
-- 20_recurring.sql — recurring earnings + deductions for one tenant.
-- Run AFTER 10_employees.sql (needs the employees rows). Many per employee,
-- sourced from the legacy AMOUNT lines. Run ONCE PER TENANT.
--
-- Runner variables: :legacy_schema :tenant_schema :cutover :system_user_id
--
-- No temp _idmap here — 10 already persisted the link. We recover it from the
-- employees table: employees.id = 'emp-<EmpNo>', employees.user_id = the key.
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"tenant_schema", public;

-- ---------------------------------------------------------------------------
-- EARNINGS. Excludes BASIC (that became the contract rate in step 4).
-- DECISION: how legacy classifies earning vs deduction (a."Kind"? sign?).
-- DECISION: taxable / uif flags — defaulted to 1/1 unless legacy carries them.
-- ---------------------------------------------------------------------------
INSERT INTO employee_recurring_earnings (
    id, employee_id, label, amount_minor, taxable, uif_applicable,
    effective_from, recorded_at, created_by_user_id, ended_at, payroll_code)
SELECT
    COALESCE((SELECT max(id) FROM employee_recurring_earnings), 0)
        + row_number() OVER (ORDER BY e.user_id, a."Code"),
    e.user_id,
    a."Description",                         -- DECISION: label source
    (a.amount * 100)::bigint,                -- DECISION: ×100 if major units
    1,                                       -- DECISION: taxable flag
    1,                                       -- DECISION: uif_applicable flag
    e.hired_at, :'cutover', :system_user_id,
    NULL,                                    -- ended_at: current line
    a."Code"                                 -- payroll_code (catalogue match key)
FROM :"legacy_schema".employee_amounts a
JOIN employees e ON e.id = 'emp-' || a."EmployeeNo"::text
WHERE a."Kind" = 'earning'                   -- DECISION: real earning predicate
  AND a."Code" <> 'BASIC'
  AND a.amount <> 0;

-- ---------------------------------------------------------------------------
-- DEDUCTIONS. reduces_taxable = pre-tax (RA/pension) vs post-tax.
-- DECISION: the pre-tax predicate.
-- ---------------------------------------------------------------------------
INSERT INTO employee_recurring_deductions (
    id, employee_id, label, amount_minor, reduces_taxable,
    effective_from, recorded_at, created_by_user_id, ended_at, payroll_code)
SELECT
    COALESCE((SELECT max(id) FROM employee_recurring_deductions), 0)
        + row_number() OVER (ORDER BY e.user_id, a."Code"),
    e.user_id,
    a."Description",
    (a.amount * 100)::bigint,
    0,                                       -- DECISION: 1 for pre-tax (RA/pension), else 0
    e.hired_at, :'cutover', :system_user_id,
    NULL,
    a."Code"
FROM :"legacy_schema".employee_amounts a
JOIN employees e ON e.id = 'emp-' || a."EmployeeNo"::text
WHERE a."Kind" = 'deduction'                 -- DECISION: real deduction predicate
  AND a.amount <> 0;

COMMIT;
\echo 'Done (recurring):' :tenant_schema '<-' :legacy_schema
