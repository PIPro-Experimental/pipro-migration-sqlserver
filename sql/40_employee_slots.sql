-- ===========================================================================
-- 40_employee_slots.sql — import the generic ordinal-slot employee values.
-- Run AFTER 10_employees.sql, ONCE PER TENANT.
--
--   settings_employee_alpha / _dates / _precision_amounts  ← legacy settings_*
--   employee_alpha / _dates / _precision_amounts / _thirdparty_payments ← legacy data
--
-- (codetype 'J' amounts are handled by 20_recurring — kept and routed to the
-- deprecated amounts table as unsupported phase-out codes, NOT moved to the dates
-- tables here. J = a DDMMYY date stuffed in an amount; a calc that hits one treats
-- it as a plain amount or logs+skips.)
--
-- Runner variables: :legacy_company_schema :tenant_schema
--                   :cutover :system_user_id
-- (accounts → employee_bank_details is handled separately; not here.)
--
-- Legacy (desktop) column names are the DataDictionary "new-name" first args.
-- CONFIRM against your desktop DB. Money (NUMERIC 19,4) → *_minor is ×100;
-- precision (NUMERIC 19,10) is carried as-is.
-- ===========================================================================
\set ON_ERROR_STOP on
-- The legacy payroll number is READ FROM THE DATA, not supplied by the runner:
-- every interim employees row carries it in payroll_f04, and one schema holds
-- one payroll. A schema with no number, or with two, stops here rather than guess.
SELECT CASE WHEN count(DISTINCT payroll_f04) = 1 AND count(payroll_f04) = count(*)
            THEN min(payroll_f04)::text
            ELSE ('no single payroll number in ' || :'legacy_company_schema' || '.employees.payroll_f04: '
                  || COALESCE(string_agg(DISTINCT payroll_f04::text, ','), 'none'))::int::text
       END AS payroll_number
FROM :"legacy_company_schema".employees \gset
BEGIN;
SET search_path TO :"tenant_schema", public;

-- ---- SETTINGS (per-tenant slot catalogues) --------------------------------
INSERT INTO settings_employee_alpha (ordinal_no, name)
SELECT ordinalno, alphaname FROM :"legacy_company_schema".settings_employee_alpha
ON CONFLICT (ordinal_no) DO NOTHING;

INSERT INTO settings_employee_dates (ordinal_no, name)
SELECT ordinalno, description FROM :"legacy_company_schema".settings_employee_dates
ON CONFLICT (ordinal_no) DO NOTHING;

INSERT INTO settings_employee_precision_amounts (ordinal_no, name, code_type, limit_value)
SELECT ordinalno, description, codetype, codelimit
FROM :"legacy_company_schema".settings_employee_precision_amounts
ON CONFLICT (ordinal_no) DO NOTHING;

-- (codetype 'J' settings are NOT imported — dropped, see header.)

-- ---- DATA (per-employee values; linked via employees.user_id) --------------
-- Employees resolve via employee_code = <payroll_number>/<EmployeeId_F01>, as 10
-- builds it: the interim EmployeeNo is unique only within one legacy database.
INSERT INTO employee_alpha (employee_id, ordinal_no, value)
SELECT e.user_id, a.ordinalno, a.reference_v
FROM :"legacy_company_schema".employee_alpha a
JOIN :"legacy_company_schema".employees le ON le.employeeno = a.employeeno
JOIN employees e ON e.employee_code = :'payroll_number' || '/' || le.employeeid_f01::text
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

INSERT INTO employee_dates (employee_id, ordinal_no, value)
SELECT e.user_id, d.ordinalno, d.date_d0::text          -- source sql format YYYY-MM-DD not null
FROM :"legacy_company_schema".employee_dates d
JOIN :"legacy_company_schema".employees le ON le.employeeno = d.employeeno
JOIN employees e ON e.employee_code = :'payroll_number' || '/' || le.employeeid_f01::text
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

INSERT INTO employee_precision_amounts (employee_id, ordinal_no, value)
SELECT e.user_id, p.ordinalno, p.amount_m               -- NUMERIC(19,10) carried as-is
FROM :"legacy_company_schema".employee_precision_amounts p
JOIN :"legacy_company_schema".employees le ON le.employeeno = p.employeeno
JOIN employees e ON e.employee_code = :'payroll_number' || '/' || le.employeeid_f01::text
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

INSERT INTO employee_thirdparty_payments (
    employee_id, ordinal_no, agent_key, agent_handling_fee_minor, agent_handling_fee_type,
    employer_handling_fee_minor, employer_handling_fee_type, monthly_deduction_amount_minor,
    stop_indicator, third_party_date, third_party_reference)
SELECT e.user_id, t.ordinalno, t.agentkey,
       (COALESCE(t.agenthandlingfee,0)*100)::bigint, t.agenthandlingfeetype,
       (COALESCE(t.employerhandlingfee,0)*100)::bigint, t.employerhandlingfeetype,
       (COALESCE(t.monthlydeductionamount,0)*100)::bigint,
       CASE WHEN t.stopindicator THEN 1 ELSE 0 END, t.thirdpartydate::text, t.thirdpartyreference
FROM :"legacy_company_schema".employee_thirdparty_payments t
JOIN :"legacy_company_schema".employees le ON le.employeeno = t.employeeno
JOIN employees e ON e.employee_code = :'payroll_number' || '/' || le.employeeid_f01::text
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

-- (codetype 'J' amount values are NOT imported — dropped, see header.)

COMMIT;
\echo 'Done (employee slots):' :tenant_schema '<-' :legacy_company_schema
