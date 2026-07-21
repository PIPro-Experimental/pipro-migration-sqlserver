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
-- Runner variables: :legacy_schema :tenant_schema :cutover :system_user_id
-- (accounts → employee_bank_details is handled separately; not here.)
--
-- Legacy (desktop) column names are the DataDictionary "new-name" first args.
-- CONFIRM against your desktop DB. Money (NUMERIC 19,4) → *_minor is ×100;
-- precision (NUMERIC 19,10) is carried as-is.
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"tenant_schema", public;

-- ---- SETTINGS (per-tenant slot catalogues) --------------------------------
INSERT INTO settings_employee_alpha (ordinal_no, name)
SELECT "OrdinalNo", "AlphaName" FROM :"legacy_schema".settings_employee_alpha
ON CONFLICT (ordinal_no) DO NOTHING;

INSERT INTO settings_employee_dates (ordinal_no, name)
SELECT "OrdinalNo", "Description" FROM :"legacy_schema".settings_employee_dates
ON CONFLICT (ordinal_no) DO NOTHING;

INSERT INTO settings_employee_precision_amounts (ordinal_no, name, code_type, limit_value)
SELECT "OrdinalNo", "Description", "CodeType", "CodeLimit"
FROM :"legacy_schema".settings_employee_precision_amounts
ON CONFLICT (ordinal_no) DO NOTHING;

-- (codetype 'J' settings are NOT imported — dropped, see header.)

-- ---- DATA (per-employee values; linked via employees.user_id) --------------
INSERT INTO employee_alpha (employee_id, ordinal_no, value)
SELECT e.user_id, a."OrdinalNo", a."Reference_V"
FROM :"legacy_schema".employee_alpha a
JOIN employees e ON e.id = 'emp-' || a."EmployeeNo"::text
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

INSERT INTO employee_dates (employee_id, ordinal_no, value)
SELECT e.user_id, d."OrdinalNo", d."Date_D0"::text          -- CONFIRM: desktop date → ISO text
FROM :"legacy_schema".employee_dates d
JOIN employees e ON e.id = 'emp-' || d."EmployeeNo"::text
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

INSERT INTO employee_precision_amounts (employee_id, ordinal_no, value)
SELECT e.user_id, p."OrdinalNo", p."Amount_M"               -- NUMERIC(19,10) carried as-is
FROM :"legacy_schema".employee_precision_amounts p
JOIN employees e ON e.id = 'emp-' || p."EmployeeNo"::text
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

INSERT INTO employee_thirdparty_payments (
    employee_id, ordinal_no, agent_key, agent_handling_fee_minor, agent_handling_fee_type,
    employer_handling_fee_minor, employer_handling_fee_type, monthly_deduction_amount_minor,
    stop_indicator, third_party_date, third_party_reference)
SELECT e.user_id, t."OrdinalNo", t."AgentKey",
       (COALESCE(t."AgentHandlingFee",0)*100)::bigint, t."AgentHandlingFeeType",
       (COALESCE(t."EmployerHandlingFee",0)*100)::bigint, t."EmployerHandlingFeeType",
       (COALESCE(t."MonthlyDeductionAmount",0)*100)::bigint,
       CASE WHEN t."StopIndicator" THEN 1 ELSE 0 END, t."ThirdPartyDate"::text, t."ThirdPartyReference"
FROM :"legacy_schema".employee_thirdparty_payments t
JOIN employees e ON e.id = 'emp-' || t."EmployeeNo"::text
ON CONFLICT (employee_id, ordinal_no) DO NOTHING;

-- (codetype 'J' amount values are NOT imported — dropped, see header.)

COMMIT;
\echo 'Done (employee slots):' :tenant_schema '<-' :legacy_schema
