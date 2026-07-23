-- ===========================================================================
-- 60_employee_accounts.sql — interim employee_accounts → employee_bank_details.
-- Run ONCE PER TENANT after 10_employees.sql. Requires the hrm-core widening
-- migration 2026_07_23_120000 (+ the pgsql CHECK drop) to be applied.
--
-- The interim table is keyed (EmployeeNo, OrdinalNo): multiple payment
-- destinations per employee with split-pay routing. ordinal_no carries the
-- slot number; the bitemporal columns are stamped with :cutover.
--
-- Runner variables: :legacy_schema :tenant_schema :cutover :system_user_id
--
-- CONFIRM: account_type receives the RAW legacy DestinAccountType code (the
--          CHECK was dropped for exactly this); mapping raw codes to
--          savings/current/transmission is a later data-driven cleanup.
-- CHOOSE:  blank account_currency defaults to 'ZAR' below.
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"tenant_schema", public;

INSERT INTO employee_bank_details (
    id, employee_id, ordinal_no,
    account_type, account_name, account_number, bank_sort_code, swift_code,
    currency, pay_mode, source_bank_account, split_pay_code,
    account_holder_status, sars_bank_account, iban,
    effective_from, recorded_at, created_by_user_id)
SELECT
    COALESCE((SELECT max(id) FROM employee_bank_details), 0)
        + row_number() OVER (ORDER BY e.user_id, s.ordinalno),
    e.user_id, s.ordinalno,
    COALESCE(NULLIF(s.accounttype_g1, ''), 'unknown'),      -- raw legacy code (CHECK dropped)
    COALESCE(s.accountname_g2, ''),                         -- target NOT NULL
    COALESCE(s.accountnumber_g3, ''),
    COALESCE(s.branchcode_g4, ''),
    NULL,                                                   -- swift_code: no interim source
    COALESCE(NULLIF(upper(s.accountcurrency_g10), ''), 'ZAR')::char(3),  -- CHOOSE: blank -> ZAR
    s.paymode_g0, s.sourcebankaccount_g5, s.splitpaycode_g6,
    s.accountholderstatus_g7,
    CASE WHEN s.sarsbankaccount_g8 THEN 1 ELSE 0 END,
    s.accountiban_g9,
    :'cutover', :'cutover', :system_user_id
FROM :"legacy_schema".employee_accounts s
JOIN employees e ON e.id = 'emp-' || s.employeeno::text
WHERE NOT EXISTS (                                          -- idempotency: skip already-carried slots
    SELECT 1 FROM employee_bank_details b
     WHERE b.employee_id = e.user_id AND b.ordinal_no = s.ordinalno);

COMMIT;
\echo 'Done (employee accounts -> bank details):' :tenant_schema '<-' :legacy_schema
