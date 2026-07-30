-- ===========================================================================
-- 70_employee_tax_status.sql — mint the per-employee tax-status row the ZA
-- run preflight requires (blocker no_tax_status without it). Run ONCE PER
-- TENANT after 10_employees.sql.
--
-- Mapping from the interim employees record:
--   resident        <- taxcountrycode_f14 blank or ZA/ZAF => 1, else 0
--   dependent_count <- taxdependants_f08 (clamped 0..50, target CHECK)
--   disability      <- 0   CONFIRM: no interim source identified; ZA
--                          disability status must be captured manually
--   age_band        <- 'derived' (pack computes from date_of_birth)
--   effective_from  <- engagement date (same anchor as the contract row)
--
-- Runner variables: :legacy_company_schema :tenant_schema :cutover :system_user_id
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"tenant_schema", public;

INSERT INTO employee_tax_status (
    employee_id, resident, dependent_count, disability, age_band,
    effective_from, recorded_at, created_by_user_id)
SELECT
    e.user_id,
    CASE WHEN COALESCE(NULLIF(upper(s.taxcountrycode_f14), ''), 'ZAF') IN ('ZA','ZAF') THEN 1 ELSE 0 END,
    LEAST(50, GREATEST(0, COALESCE(s.taxdependants_f08, 0))),
    0,
    'derived',
    s.engagedate_d931::text,
    :'cutover', :system_user_id
FROM :"legacy_company_schema".employees s
JOIN employees e ON e.id = 'emp-' || s.employeeno::text
WHERE NOT EXISTS (                                   -- idempotency
    SELECT 1 FROM employee_tax_status t WHERE t.employee_id = e.user_id);

COMMIT;
\echo 'Done (employee tax status):' :tenant_schema '<-' :legacy_company_schema
