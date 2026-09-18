-- ===========================================================================
-- 90_employee_map.sql — the DURABLE three-stage employee key bridge, and the
-- import-integrity report that falls out of building it. Read-only against
-- both source and tenant; writes only to the `compare` schema.
--
-- Runner variables: :legacy_company_schema :tenant_schema
--
-- WHY THIS EXISTS
-- ---------------
-- The employee key is re-minted TWICE on the way from SQL Server to pipro, and
-- at each stage the previous key survives only as a COLUMN ON THE EMPLOYEES
-- TABLE — never on the child rows:
--
--   stage     legacy number lives in        child rows key on
--   -------   ---------------------------   ---------------------------------
--   legacy    pw_imf.EmpNo                  pw_amts.EmpNo        (same value)
--   interim   employees.employeeid_f01      employees.employeeno (AUTO_KEY)
--   pipro     employees.employee_code       pipro_core_users.id  (identity)
--
-- DataDictionary.java:811 declares the interim employeeno as DataType.AUTO_KEY
-- and :815 maps employeeid_f01 <- legacy EmpNo. SQLImport.lookupEmployee (:1882)
-- translates child rows onto the new auto-key through an IN-MEMORY map that is
-- never persisted. So no child row in either target system can be tied back to
-- a legacy employee without reading `employees` at both ends. This table is
-- that read, made durable.
--
-- THE TRAP THIS REPLACES
-- ----------------------
-- Joining employees.id = 'emp-' || <legacy EmpNo> appears to work and is wrong:
-- 'emp-N' is built from the INTERIM SURROGATE, not the legacy number. On
-- tenant_test_airplane the two coincide for all 187 rows (legacy EmpNos are a
-- contiguous 1..187, auto-keys were assigned in that order into an empty
-- table), which is why compare.july_diff reconciled. A client with ANY gap in
-- EmpNo, non-contiguous numbering, or a different insert order gets silently
-- MISMATCHED rows — employee A's legacy values against employee B's pipro
-- values — not an empty join. Section 6 asserts the coincidence explicitly so
-- it can never be leaned on again by accident.
--
-- THE SPINE is employee_code: interim employeeid_f01 = pipro employee_code =
-- legacy EmpNo-as-text. It is the only value that survives both re-mintings.
--
-- Marker legend:
--   CONFIRM = source settled; verify your data satisfies the rule.
--   CHOOSE  = a genuine decision.
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE SCHEMA IF NOT EXISTS compare;

-- ---------------------------------------------------------------------------
-- The map. One row per employee_code per tenant, carrying every stage's key.
-- legacy_empno stays NULL until a SQL Server export lands.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS compare.employee_map (
    tenant_schema     TEXT    NOT NULL,
    employee_code     TEXT    NOT NULL,          -- the spine
    interim_empno     INTEGER,                   -- airplane.employees.employeeno (AUTO_KEY)
    pipro_employee_id TEXT,                      -- tenant.employees.id ('emp-<interim_empno>')
    pipro_user_id     BIGINT,                    -- tenant.employees.user_id — what child rows key on
    legacy_empno      TEXT,                      -- pw_imf.EmpNo, filled from a SQL Server export
    surname           TEXT,
    status            TEXT    NOT NULL,          -- matched | interim_only | pipro_only
    note              TEXT,
    built_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_schema, employee_code)
);

-- Idempotent: this tenant's rows are rebuilt from scratch on every run.
DELETE FROM compare.employee_map WHERE tenant_schema = :'tenant_schema';

-- ---------------------------------------------------------------------------
-- Section 1: build the map. FULL OUTER JOIN so a break in EITHER direction
-- shows up as a row rather than as a missing one — that is the whole point.
--
-- CONFIRM: the spine is compared on btrim() only. If a client's legacy EmpNo
-- carries leading zeros in one stage and not the other, widen this to a
-- canonicalising expression on BOTH sides (and nowhere else).
-- ---------------------------------------------------------------------------
INSERT INTO compare.employee_map (
    tenant_schema, employee_code, interim_empno, pipro_employee_id,
    pipro_user_id, surname, status, note)
SELECT
    :'tenant_schema',
    COALESCE(btrim(a.employeeid_f01), btrim(t.employee_code)),
    a.employeeno,
    t.id,
    t.user_id,
    COALESCE(a.surname_f02, t.last_name),
    CASE
        WHEN a.employeeno IS NULL THEN 'pipro_only'
        WHEN t.id         IS NULL THEN 'interim_only'
        ELSE 'matched'
    END,
    CASE
        -- The hrm-core tenant migration seeds this row into EVERY tenant
        -- (2026_05_18_140100_seed_demo_employee.sql); its own comment says
        -- production wipes it later. Expected noise, not an import defect.
        WHEN t.id = 'emp-dev-0001' THEN 'seeded demo employee — expected'
        WHEN a.employeeno IS NULL  THEN 'in pipro but not in the interim source'
        WHEN t.id         IS NULL  THEN 'in the interim source but NOT imported — see section 2'
    END
FROM      :"legacy_company_schema".employees a
FULL JOIN :"tenant_schema".employees        t
       ON btrim(t.employee_code) = btrim(a.employeeid_f01);

COMMIT;

-- ===========================================================================
-- The integrity report.
-- ===========================================================================
\echo ''
\echo '=== 1. Map summary ========================================================'
SELECT status, count(*) AS employees
FROM compare.employee_map WHERE tenant_schema = :'tenant_schema'
GROUP BY status ORDER BY status;

\echo ''
\echo '=== 2. Employees in the source that did NOT reach pipro ===================='
-- 10_employees.sql step 3 ends with ON CONFLICT (employee_code) DO NOTHING, so a
-- duplicate or blank legacy code drops the employee SILENTLY. Worse, the login
-- user is minted in step 2 BEFORE that conflict fires, so each dropped employee
-- also strands an orphan pipro_core_users row (section 8). Any row here is that
-- failure, and it is the check the whole exercise exists for.
SELECT employee_code, interim_empno, surname
FROM compare.employee_map
WHERE tenant_schema = :'tenant_schema' AND status = 'interim_only'
ORDER BY interim_empno;

\echo ''
\echo '=== 3. Rows in pipro with no source counterpart ============================'
SELECT employee_code, pipro_employee_id, pipro_user_id, surname, note
FROM compare.employee_map
WHERE tenant_schema = :'tenant_schema' AND status = 'pipro_only'
ORDER BY employee_code;

\echo ''
\echo '=== 4. Duplicate-code check (the cause of a silent drop) ==================='
SELECT btrim(employeeid_f01) AS employee_code, count(*) AS source_rows
FROM :"legacy_company_schema".employees
GROUP BY 1 HAVING count(*) > 1
ORDER BY 1;

\echo ''
\echo '=== 5. Blank / zero employee codes in the source ==========================='
-- Owner decision 2026-09-17: the legacy default ("employee zero") template row
-- is DROPPED, not migrated — the interim import filters pw_* to EmpNo > 0.
-- Any row here means that filter has not reached this source copy yet.
SELECT employeeno, employeeid_f01, surname_f02
FROM :"legacy_company_schema".employees
WHERE employeeid_f01 IS NULL OR btrim(employeeid_f01) = ''
   OR btrim(employeeid_f01) ~ '^0+$'
ORDER BY employeeno;

\echo ''
\echo '=== 6. TRAP CHECK: does the interim surrogate coincide with the code? ======'
-- If coincide < total, any query joining 'emp-' || <legacy EmpNo> is SILENTLY
-- MISMATCHING rows. compare.july_diff does exactly that and survives only
-- because this client scores 100%. Never propagate that join; use this map.
SELECT count(*) AS total,
       count(*) FILTER (WHERE interim_empno::text = employee_code) AS coincide,
       CASE WHEN count(*) = count(*) FILTER (WHERE interim_empno::text = employee_code)
            THEN 'coincidence holds — legacy-keyed joins happen to work HERE'
            ELSE 'BROKEN — legacy-keyed joins are mismatching rows; use the map'
       END AS verdict
FROM compare.employee_map
WHERE tenant_schema = :'tenant_schema' AND status = 'matched';

\echo ''
\echo '=== 7. Orphan child rows in the interim source ============================='
SELECT 'employee_amounts' AS child_table, count(*) AS orphan_rows
FROM :"legacy_company_schema".employee_amounts c
LEFT JOIN :"legacy_company_schema".employees e ON e.employeeno = c.employeeno
WHERE e.employeeno IS NULL
UNION ALL SELECT 'employee_alpha', count(*)
FROM :"legacy_company_schema".employee_alpha c
LEFT JOIN :"legacy_company_schema".employees e ON e.employeeno = c.employeeno
WHERE e.employeeno IS NULL
UNION ALL SELECT 'employee_dates', count(*)
FROM :"legacy_company_schema".employee_dates c
LEFT JOIN :"legacy_company_schema".employees e ON e.employeeno = c.employeeno
WHERE e.employeeno IS NULL;

\echo ''
\echo '=== 8. Orphan users minted for employees that were then dropped ==========='
SELECT count(*) AS orphan_users
FROM public.pipro_core_users u
WHERE u.password_hash = '!migrated-no-login'
  AND NOT EXISTS (SELECT 1 FROM :"tenant_schema".employees e WHERE e.user_id = u.id);
