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
-- names are from DataDictionary.java — CONFIRM against your desktop DB.
--
-- Marker legend:
--   CONFIRM = source is settled; just verify your data satisfies the target
--             rule (uniqueness / not-null / format), or that the stated
--             behaviour is acceptable. No column choice needed.
--   CHOOSE  = a genuine decision — pick the source column, transform, or rule.
--
-- Identity note (see README): pipro_core_users is a system USER/operator login;
-- pipro REQUIRES every employee to have one, so we MINT a login-user per
-- employee. Legacy integer EmployeeNo → the minted user_id (via _idmap); the
-- alpha EmployeeId_F01 → employee_code.
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"tenant_schema", public;

-- ---------------------------------------------------------------------------
-- Step 1: stage + normalise source rows (all conversions happen here).
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _src ON COMMIT DROP AS
SELECT
    e."EmployeeNo"::text                               AS legacy_empno,       -- join key → minted user_id
    e."EmployeeId_F01"::text                           AS employee_code,      -- SQL server EmpNo - unique, non-blank, numeric, possible zero
    e."Surname_F02"                                    AS last_name,
    e."GivenNames_F21"                                 AS first_name,
    e."Identity_F12"::text                             AS id_number,
    e."BirthDate_D930"::text                           AS date_of_birth,      -- source sql format YYYY-MM-DD not null
    e."EngageDate_D931"::text                          AS hired_at,           -- source sql format YYYY-MM-DD not null
    NULLIF(e."DischargeDate_D932"::text, '')           AS terminated_at,      -- source sql format YYYY-MM-DD mostly null
    e."Title_F28"                                      AS title,
    e."Occupation_F11"                                 AS occupation,
    e."Category_F13"                                   AS category,
    'unspecified'                                      AS marital_status,
    1                                                  AS currency,
    upper(nullif(e."TaxCountryCode_F14", ''))::char(3) AS nationality_country_code, -- there are two sets of country codes, one char(2) & one char(3)
    CASE upper(left(coalesce(e."Gender_F22",''),1)) WHEN 'M' THEN 'male' WHEN 'F' THEN 'female' ELSE 'unspecified' END AS gender,
    COALESCE(NULLIF(e."EmailAddress_F40", ''), e."EmployeeId_F01"::text || '@migrated.invalid') AS email,        -- synthesise when F40 blank
    (COALESCE(a.amount, 0) * 100)::bigint              AS rate_minor,
FROM :"legacy_schema".employees e
LEFT JOIN :"legacy_schema".employee_amounts a
LEFT JOIN :"legacy_schema".settings_taxcodes t
       ON a."EmployeeNo" = e."EmployeeNo"
	   AND a."Payroll_F04" = t."Payroll"
	   AND e."OrdinalNo" = t."BasicCode"
	   WHERE t.Currency = 1;

-- ---------------------------------------------------------------------------
-- Step 2: pipro_core_users (public) — MINT one login-user per employee and
-- capture the generated BIGINT id (the key pipro's payroll tables use for the
-- employee). Columns are the REAL table: password_hash is NOT NULL — migrated
-- users get an unusable placeholder and cannot log in until a reset (irrelevant
-- to payroll; the engine never reads this table). is_active is an int flag.
-- NOTE: this is NOT the migration of your legacy OPERATOR accounts — that's a
-- separate concern; an operator who is also an employee may need de-duping later.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _idmap (legacy_empno TEXT PRIMARY KEY, user_id BIGINT) ON COMMIT DROP;

DO $$
DECLARE r record; new_uid bigint;
BEGIN
  FOR r IN SELECT * FROM _src LOOP
    INSERT INTO public.pipro_core_users
        (email, password_hash, first_name, last_name, is_active, created_at)
    VALUES
        (r.email, '!migrated-no-login', r.first_name, r.last_name, 1, current_timestamp::text)
    RETURNING id INTO new_uid;
    INSERT INTO _idmap (legacy_empno, user_id) VALUES (r.legacy_empno, new_uid);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Step 3: employees. id is a TEXT PK — the app fills it with random hex; we use
-- deterministic 'emp-<EmpNo>' so it's idempotent AND preserves a trace back to
-- the legacy EmployeeNo. (This TEXT id is used only by hrm self-refs like
-- manager_id; the PAYROLL domain keys on user_id — see identity note.)
-- ---------------------------------------------------------------------------
INSERT INTO employees (
    id, user_id, employee_code, first_name, last_name, email, id_number,
    hired_at, terminated_at, salary_current_minor, currency, created_at,
    date_of_birth, gender, title, nationality_country_code, marital_status, preferred_name,
    occupation, category)
SELECT
    'emp-' || s.legacy_empno, m.user_id, s.employee_code, s.first_name, s.last_name,
    s.email, s.id_number, s.hired_at, s.terminated_at, s.rate_minor, s.currency,
    :'cutover', s.date_of_birth, s.gender, s.title, s.nationality_country_code,
    s.marital_status, NULL, s.occupation, s.category
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
    40.00,              -- CHOOSE: hours_per_week
    NULL,               -- CHOOSE: org_unit_id (map dept → org_units(id))
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
-- 'active' row at hire + a 'terminated' row at discharge.
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
-- Step 7 (second pass): manager_id self-FK (references employees.id TEXT).
-- CHOOSE: needs the legacy reports-to EmpNo column; stubbed.
-- ---------------------------------------------------------------------------
-- UPDATE employees c SET manager_id = 'emp-' || src."ManagerEmpNo"
-- FROM :"legacy_schema".employees src
-- WHERE src."EmployeeNo"::text = substring(c.id from 5);

COMMIT;
\echo 'Done (core):' :tenant_schema '<-' :legacy_schema
