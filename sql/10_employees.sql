-- ===========================================================================
-- 10_employees.sql — the CORE employee record for one tenant, from one legacy
-- source schema. Run ONCE PER TENANT. Creates, in dependency order:
--   pipro_core_users → employees → employee_contracts
--                    → employee_payroll_assignments  (puts them in the run worklist)
--                    → employee_status_history        (payable gate)
--
-- Runner variables: :legacy_schema :tenant_schema :target_payroll_id
--                   :cutover :system_user_id     (see run-migration.ps1)
--
-- Target columns/types are VERBATIM from the live schema (real). Source column
-- names are from DataDictionary.java — CONFIRM against your desktop DB. Every
-- mapping choice is flagged -- DECISION.
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"tenant_schema", public;

-- ---------------------------------------------------------------------------
-- Step 1: stage + normalise source rows (all conversions happen here).
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _src ON COMMIT DROP AS
SELECT
    e."EmployeeNo"::text                               AS legacy_empno,
    e."EmployeeId_F01"::text                           AS employee_code,     -- DECISION: code source
    e."Surname_F02"                                    AS last_name,
    e."GivenNames_F21"                                 AS first_name,
    COALESCE(NULLIF(e."EmailAddress_F40", ''),
             e."EmployeeId_F01"::text || '@migrated.invalid') AS email,       -- DECISION
    e."Identity_F12"::text                             AS id_number,
    e."BirthDate_D930"::text                           AS date_of_birth,      -- DECISION: assumes ISO/castable
    e."EngageDate_D931"::text                          AS hired_at,           -- NOT NULL in target
    NULLIF(e."DischargeDate_D932"::text, '')           AS terminated_at,
    e."Title_F28"                                      AS title,
    CASE upper(left(coalesce(e."Gender_F22",''),1))
        WHEN 'M' THEN 'male' WHEN 'F' THEN 'female' ELSE 'unspecified' END AS gender, -- DECISION
    'unspecified'                                      AS marital_status,     -- DECISION
    upper(nullif(e."PassportCountry_F46", ''))::char(2) AS nationality_country_code, -- DECISION: ISO-2
    -- Basic monthly rate lives on the legacy AMOUNT line, not the masterfile.
    -- DECISION: confirm BASIC code + major-units (×100). If already minor, drop *100.
    (COALESCE(a.amount, 0) * 100)::bigint              AS rate_minor,
    upper(coalesce(nullif(e."TaxCountryCode_F14",''),'ZA'))::char(3)         AS currency -- DECISION
FROM :"legacy_schema".employees e
LEFT JOIN :"legacy_schema".employee_amounts a         -- DECISION: real rate table/cols
       ON a."EmployeeNo" = e."EmployeeNo" AND a."Code" = 'BASIC';            -- DECISION: BASIC code

-- ---------------------------------------------------------------------------
-- Step 2: pipro_core_users (public) — one per employee; capture the generated
-- BIGINT id (the operational link key). Columns are the REAL table:
-- password_hash is NOT NULL — migrated users get an unusable placeholder and
-- cannot log in until a password-reset/invite (irrelevant to payroll runs; the
-- engine never reads this table). is_active is an int flag, not a status text.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _idmap (legacy_empno TEXT PRIMARY KEY, user_id BIGINT) ON COMMIT DROP;

DO $$
DECLARE r record; new_uid bigint;
BEGIN
  FOR r IN SELECT * FROM _src LOOP
    INSERT INTO public.pipro_core_users
        (email, password_hash, first_name, last_name, is_active, created_at)
    VALUES
        (r.email, '!migrated-no-login',   -- DECISION: unusable hash; reset before login
         r.first_name, r.last_name, 1, current_timestamp::text)
    RETURNING id INTO new_uid;
    INSERT INTO _idmap (legacy_empno, user_id) VALUES (r.legacy_empno, new_uid);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Step 3: employees. id is TEXT PK — deterministic 'emp-<EmpNo>' so it's
-- idempotent AND usable as the manager_id self-FK (and by 20_recurring.sql).
-- ---------------------------------------------------------------------------
INSERT INTO employees (
    id, user_id, employee_code, first_name, last_name, email, id_number,
    hired_at, terminated_at, salary_current_minor, currency, created_at,
    date_of_birth, gender, title, nationality_country_code, marital_status, preferred_name)
SELECT
    'emp-' || s.legacy_empno, m.user_id, s.employee_code, s.first_name, s.last_name,
    s.email, s.id_number, s.hired_at, s.terminated_at, s.rate_minor, s.currency,
    :'cutover', s.date_of_birth, s.gender, s.title, s.nationality_country_code,
    s.marital_status, NULL
FROM _src s JOIN _idmap m ON m.legacy_empno = s.legacy_empno
ON CONFLICT (employee_code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Step 4: employee_contracts — bitemporal fan-out. One current monthly
-- contract; id is manual MAX+1 (BIGINT, no IDENTITY); rate_minor CHECK (> 0).
-- ---------------------------------------------------------------------------
INSERT INTO employee_contracts (
    id, employee_id, rate_type, rate_minor, currency, hours_per_week,
    org_unit_id, effective_from, recorded_at, created_by_user_id)
SELECT
    COALESCE((SELECT max(id) FROM employee_contracts), 0) + row_number() OVER (ORDER BY m.user_id),
    m.user_id, 'monthly', s.rate_minor, s.currency,
    40.00,              -- DECISION: hours_per_week
    NULL,               -- DECISION: org_unit_id
    s.hired_at, :'cutover', :system_user_id
FROM _src s JOIN _idmap m ON m.legacy_empno = s.legacy_empno
WHERE s.rate_minor > 0;   -- CHECK (rate_minor > 0); rateless rows get no contract

-- ---------------------------------------------------------------------------
-- Step 5: employee_payroll_assignments — WITHOUT this the engine's worklist
-- never sees the employee. payroll_id = the tenant payroll from the map.
-- ---------------------------------------------------------------------------
INSERT INTO employee_payroll_assignments (
    id, employee_id, payroll_id, effective_from, recorded_at, created_by_user_id)
SELECT
    COALESCE((SELECT max(id) FROM employee_payroll_assignments), 0) + row_number() OVER (ORDER BY m.user_id),
    m.user_id, :target_payroll_id, s.hired_at, :'cutover', :system_user_id
FROM _src s JOIN _idmap m ON m.legacy_empno = s.legacy_empno;

-- ---------------------------------------------------------------------------
-- Step 6: employee_status_history — the engine treats ABSENT as active, so we
-- only strictly need a 'terminated' row for discharged staff. We write an
-- 'active' row at hire for completeness + a 'terminated' row at discharge.
-- status CHECK IN ('active','suspended','terminated').
-- ---------------------------------------------------------------------------
INSERT INTO employee_status_history (id, employee_id, status, effective_from, recorded_at, created_by_user_id)
SELECT
    COALESCE((SELECT max(id) FROM employee_status_history), 0) + row_number() OVER (ORDER BY m.user_id, k.ord),
    m.user_id, k.status, k.eff, :'cutover', :system_user_id
FROM _src s
JOIN _idmap m ON m.legacy_empno = s.legacy_empno
CROSS JOIN LATERAL (VALUES
    (1, 'active',     s.hired_at),
    (2, 'terminated', s.terminated_at)
) AS k(ord, status, eff)
WHERE k.eff IS NOT NULL;   -- the 'terminated' row only when a discharge date exists

-- ---------------------------------------------------------------------------
-- Step 7 (second pass): manager_id self-FK. DECISION: needs the legacy
-- reports-to EmpNo column; stubbed.
-- ---------------------------------------------------------------------------
-- UPDATE employees c SET manager_id = 'emp-' || src."ManagerEmpNo"
-- FROM :"legacy_schema".employees src
-- WHERE src."EmployeeNo"::text = substring(c.id from 5);

COMMIT;
\echo 'Done (core):' :tenant_schema '<-' :legacy_schema
