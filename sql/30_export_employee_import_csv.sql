-- ===========================================================================
-- 30_export_employee_import_csv.sql — ALTERNATIVE to 10/20 for employee master
-- data: generate the CSV the pipro EmployeeImportController expects, so the load
-- goes through the APP importer instead of raw INSERTs. You then get, per row:
-- validation (required/format/in-batch dedup), correct per-employee user minting,
-- an AUDIT trail, and PARENT+CHILD atomicity (one CSV row = one transaction).
--
-- Run against wherever the legacy tables live (desktop DB, or the docker DB's
-- legacy_<schema>). Pipe STDOUT to a file, then upload it via the import UI /
-- endpoint (csv format):
--
--   psql ... -v legacy_schema=legacy_acme -f 30_export_employee_import_csv.sql > acme_employees.csv
--
-- ---------------------------------------------------------------------------
-- SCOPE — the importer models the COMMON case, NOT every legacy amount line.
--   * Recurring lines are FIXED named slots: travel/housing/cell allowances +
--     retirement/medical deductions. Arbitrary legacy amount codes beyond these
--     are NOT representable in the CSV — load those via 20_recurring.sql instead
--     (or add more ImportableFields to the app).
--   * The column KEYS below are the importer's ImportableField keys (= the CSV
--     header the app parses). The master + payroll-core keys are confirmed from
--     the field registry; child-table columns (addresses, bank details, tax
--     status, phones, next-of-kin, loans) ALSO exist — pull the exact keys from
--     the app's import TEMPLATE endpoint and add them as columns here.
-- ---------------------------------------------------------------------------
\set ON_ERROR_STOP on
COPY (
    SELECT
        e.employeeid_f01                                          AS employee_code,
        e.givennames_f21                                          AS first_name,
        e.surname_f02                                             AS last_name,
        COALESCE(NULLIF(e.emailaddress_f40,''), e.employeeid_f01 || '@migrated.invalid')         AS email,
        e.engagedate_d931                                         AS hired_at,         -- YYYY-MM-DD
        e.identity_f12                                            AS id_number,
        (COALESCE(bas.amount,0)  * 100)::bigint                     AS salary_minor,     -- CONFIRM: BASIC line, ×100
        upper(coalesce(nullif(e.taxcountrycode_f14,''),'ZA'))     AS currency,         -- CHOOSE
        (COALESCE(trav.amount,0) * 100)::bigint                     AS allowance_travel_minor,      -- CHOOSE: legacy code
        (COALESCE(hous.amount,0) * 100)::bigint                     AS allowance_housing_minor,     -- CHOOSE
        (COALESCE(cell.amount,0) * 100)::bigint                     AS allowance_cell_minor,        -- CHOOSE
        (COALESCE(ret.amount,0)  * 100)::bigint                     AS deduction_retirement_minor,  -- CHOOSE
        (COALESCE(medd.amount,0) * 100)::bigint                     AS deduction_medical_minor      -- CHOOSE
		
		????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
		
        -- + medical_scheme_name, medical_dependants, and the address / bank /
        --   tax-status / phone / next-of-kin / loan columns — add once you've
        --   pulled their exact keys from the import template.
    FROM :"legacy_schema".employees e
    LEFT JOIN :"legacy_schema".employee_amounts bas  ON bas.employeeno  = e.employeeno AND bas.code  = 'BASIC'    -- CHOOSE codes ↓
    LEFT JOIN :"legacy_schema".employee_amounts trav ON trav.employeeno = e.employeeno AND trav.code = 'TRAVEL'
    LEFT JOIN :"legacy_schema".employee_amounts hous ON hous.employeeno = e.employeeno AND hous.code = 'HOUSING'
    LEFT JOIN :"legacy_schema".employee_amounts cell ON cell.employeeno = e.employeeno AND cell.code = 'CELL'
    LEFT JOIN :"legacy_schema".employee_amounts ret  ON ret.employeeno  = e.employeeno AND ret.code  = 'RA'
    LEFT JOIN :"legacy_schema".employee_amounts medd ON medd.employeeno = e.employeeno AND medd.code = 'MEDICAL'
    ORDER BY e.employeeno
) TO STDOUT WITH (FORMAT csv, HEADER true);
