-- ===========================================================================
-- 15_catalogue_merge.sql - build ONE set of employee-data catalogues for a
-- tenant out of every payroll in migration_map, report every disagreement, and
-- (with apply=1) write the merged catalogues into the tenant.
--
-- WHY: a tenant holds ONE catalogue per kind of employee data, but each legacy
-- payroll database had its own (PW_Parm_Codes, date / indicator / refno names,
-- registers). Values stay addressed by ORDINAL, so the payrolls can share a
-- catalogue as long as no ordinal means two different things. Without this step
-- 20/40 insert each payroll's catalogue with ON CONFLICT DO NOTHING, so the first
-- payroll's name silently wins - and E/D lines are labelled by NAME, which would
-- detach a later payroll's line from its code.
--
-- CATALOGUES (interim source -> tenant), ordinals as the INTERIM numbers them:
--   amounts    settings_employee_amounts            values: employee_amounts (Q)
--   alpha      settings_employee_alpha              values: employee_alpha (V;
--              indicators as-is, refnos at ordinal + 100)
--   dates      settings_employee_dates              values: employee_dates (D)
--   precision  settings_employee_precision_amounts  values: employee_precision_amounts
--
-- VERDICT per (catalogue, ordinal), first match wins:
--   CONFLICT_TYPE   payrolls HOLDING VALUES on this ordinal disagree on the code
--                   type. Blocking, and an override cannot fix it: the values are
--                   routed by their own payroll's type, so one side would land in
--                   the wrong table. Needs a legacy renumber.
--   override        catalogue-overrides.csv names it (name only).
--   CONFLICT_NAME   payrolls HOLDING VALUES disagree on the name. Blocking until
--                   an override names it.
--   CONFLICT_DUPLICATE_NAME  (set afterwards, section 2b) the name chosen here is
--                   also chosen for another ordinal, and two or more of them hold
--                   values. Blocking until an override renames all but one.
--   same            every payroll that defines it agrees (case/spacing ignored).
--   named_by_data   names differ, but only one name has values behind it - that
--                   name wins; the others are unused labels.
--   unused_differs  names differ and nobody holds values - the largest payroll's
--                   name wins.
-- Informational, never blocking: `partial` (not every payroll defines the
-- ordinal), `types differ` on the unused side, `differ: <columns>` (tax type,
-- limit, display flags...) - the payroll whose name was chosen supplies them.
--
-- The chosen source row: one holding values first, then the payroll with most
-- employees, then the lowest payroll number.
--
-- Runner variables: :tenant_slug :tenant_schema :apply (0 = report only)
-- Writes: migration.catalogue_source / catalogue_merge (this tenant's rows
-- replaced), and with apply=1 the tenant's four settings_employee_* tables.
-- ===========================================================================
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL mig.tenant_slug   = :'tenant_slug';
SET LOCAL mig.tenant_schema = :'tenant_schema';
SET LOCAL mig.apply         = :'apply';

CREATE SCHEMA IF NOT EXISTS migration;

CREATE TABLE IF NOT EXISTS migration.catalogue_override (
    tenant_slug TEXT NOT NULL, catalogue TEXT NOT NULL, ordinal_no INTEGER NOT NULL,
    name TEXT NOT NULL, note TEXT,
    PRIMARY KEY (tenant_slug, catalogue, ordinal_no));

CREATE TABLE IF NOT EXISTS migration.catalogue_source (
    tenant_slug TEXT NOT NULL, catalogue TEXT NOT NULL, source_schema TEXT NOT NULL,
    payroll_number INTEGER NOT NULL, employees INTEGER NOT NULL,
    ordinal_no INTEGER NOT NULL, name TEXT, code_type TEXT,
    currency_code TEXT, code_limit_minor BIGINT, tax_type TEXT, tax_inc_asn TEXT,
    consol_code INTEGER, adjust_flag TEXT, manual_display INTEGER, prorata INTEGER,
    qmf_display INTEGER, limit_value NUMERIC,
    data_rows INTEGER NOT NULL,
    PRIMARY KEY (tenant_slug, catalogue, source_schema, ordinal_no));

CREATE TABLE IF NOT EXISTS migration.catalogue_merge (
    tenant_slug TEXT NOT NULL, catalogue TEXT NOT NULL, ordinal_no INTEGER NOT NULL,
    verdict TEXT NOT NULL, notes TEXT, chosen_source TEXT NOT NULL, chosen_name TEXT,
    data_rows INTEGER NOT NULL, variants TEXT NOT NULL,
    PRIMARY KEY (tenant_slug, catalogue, ordinal_no));

-- ---- 1. Collect every payroll's catalogues, with how many values sit behind each ordinal
DO $$
DECLARE
    t   TEXT := current_setting('mig.tenant_slug');
    m   RECORD;
    emp INTEGER;
BEGIN
    DELETE FROM migration.catalogue_source WHERE tenant_slug = t;
    IF NOT EXISTS (SELECT 1 FROM migration_map WHERE tenant_slug = t) THEN
        RAISE EXCEPTION 'migration_map has no rows for tenant %', t;
    END IF;

    FOR m IN SELECT legacy_company_schema AS s, legacy_payroll_number AS p
             FROM migration_map WHERE tenant_slug = t ORDER BY legacy_payroll_number
    LOOP
        EXECUTE format('SELECT count(*) FROM %I.employees', m.s) INTO emp;

        EXECUTE format($q$
            INSERT INTO migration.catalogue_source (tenant_slug, catalogue, source_schema, payroll_number, employees,
                ordinal_no, name, code_type, currency_code, code_limit_minor, tax_type, tax_inc_asn, consol_code,
                adjust_flag, manual_display, prorata, qmf_display, data_rows)
            SELECT $1, 'amounts', $2, $3, $4, c.ordinalno, c.description, upper(nullif(btrim(c.codetype), '')),
                   c.currency_code, (COALESCE(c.codelimit, 0) * 100)::bigint, c.taxtype, c.taxincasn, c.consolcode,
                   c.adjustflag,
                   CASE WHEN c.manualdisplayind THEN 1 ELSE 0 END,
                   CASE WHEN c.prorataind       THEN 1 ELSE 0 END,
                   CASE WHEN c.qmfdisplayind    THEN 1 ELSE 0 END,
                   (SELECT count(*) FROM %1$I.employee_amounts v WHERE v.ordinalno = c.ordinalno AND v.amount_q <> 0)
            FROM %1$I.settings_employee_amounts c$q$, m.s) USING t, m.s, m.p, emp;

        EXECUTE format($q$
            INSERT INTO migration.catalogue_source (tenant_slug, catalogue, source_schema, payroll_number, employees,
                ordinal_no, name, data_rows)
            SELECT $1, 'alpha', $2, $3, $4, c.ordinalno, c.alphaname,
                   (SELECT count(*) FROM %1$I.employee_alpha v WHERE v.ordinalno = c.ordinalno AND btrim(COALESCE(v.reference_v, '')) <> '')
            FROM %1$I.settings_employee_alpha c$q$, m.s) USING t, m.s, m.p, emp;

        EXECUTE format($q$
            INSERT INTO migration.catalogue_source (tenant_slug, catalogue, source_schema, payroll_number, employees,
                ordinal_no, name, data_rows)
            SELECT $1, 'dates', $2, $3, $4, c.ordinalno, c.description,
                   (SELECT count(*) FROM %1$I.employee_dates v WHERE v.ordinalno = c.ordinalno AND v.date_d0 IS NOT NULL)
            FROM %1$I.settings_employee_dates c$q$, m.s) USING t, m.s, m.p, emp;

        EXECUTE format($q$
            INSERT INTO migration.catalogue_source (tenant_slug, catalogue, source_schema, payroll_number, employees,
                ordinal_no, name, code_type, limit_value, data_rows)
            SELECT $1, 'precision', $2, $3, $4, c.ordinalno, c.description, upper(nullif(btrim(c.codetype), '')), c.codelimit,
                   (SELECT count(*) FROM %1$I.employee_precision_amounts v WHERE v.ordinalno = c.ordinalno AND v.amount_m <> 0)
            FROM %1$I.settings_employee_precision_amounts c$q$, m.s) USING t, m.s, m.p, emp;
    END LOOP;
END $$;

-- ---- 2. Decide each ordinal
DELETE FROM migration.catalogue_merge WHERE tenant_slug = current_setting('mig.tenant_slug');

WITH src AS (
    SELECT s.*, upper(btrim(regexp_replace(COALESCE(s.name, ''), '\s+', ' ', 'g'))) AS nkey
    FROM migration.catalogue_source s WHERE s.tenant_slug = current_setting('mig.tenant_slug')),
payrolls AS (
    SELECT count(DISTINCT source_schema) AS n FROM src),
agg AS (
    SELECT catalogue, ordinal_no,
           count(*)                                                              AS n_sources,
           count(DISTINCT nkey)                                                  AS n_names,
           count(DISTINCT nkey) FILTER (WHERE data_rows > 0)                     AS n_names_data,
           count(DISTINCT COALESCE(code_type, ''))                               AS n_types,
           count(DISTINCT COALESCE(code_type, '')) FILTER (WHERE data_rows > 0)  AS n_types_data,
           NULLIF(concat_ws(' ',
               CASE WHEN count(DISTINCT COALESCE(tax_type, ''))             > 1 THEN 'tax_type' END,
               CASE WHEN count(DISTINCT COALESCE(tax_inc_asn, ''))          > 1 THEN 'tax_inc_asn' END,
               CASE WHEN count(DISTINCT COALESCE(code_limit_minor, 0))      > 1 THEN 'limit' END,
               CASE WHEN count(DISTINCT COALESCE(limit_value, 0))           > 1 THEN 'limit' END,
               CASE WHEN count(DISTINCT COALESCE(currency_code, ''))        > 1 THEN 'currency' END,
               CASE WHEN count(DISTINCT COALESCE(consol_code, -1))          > 1 THEN 'consol_code' END,
               CASE WHEN count(DISTINCT COALESCE(adjust_flag, ''))          > 1 THEN 'adjust_flag' END,
               CASE WHEN count(DISTINCT COALESCE(manual_display, -1))       > 1 THEN 'manual_display' END,
               CASE WHEN count(DISTINCT COALESCE(prorata, -1))              > 1 THEN 'prorata' END,
               CASE WHEN count(DISTINCT COALESCE(qmf_display, -1))          > 1 THEN 'qmf_display' END), '') AS flag_cols,
           sum(data_rows)::int                                                   AS data_rows,
           string_agg(source_schema || ': ' || COALESCE(code_type || ' ', '') || COALESCE(btrim(name), '(blank)')
                      || ' [' || data_rows || ']', '  |  ' ORDER BY payroll_number) AS variants
    FROM src GROUP BY catalogue, ordinal_no),
chosen AS (
    SELECT DISTINCT ON (catalogue, ordinal_no) catalogue, ordinal_no, source_schema, name
    FROM src ORDER BY catalogue, ordinal_no, (data_rows > 0) DESC, employees DESC, payroll_number)
INSERT INTO migration.catalogue_merge (tenant_slug, catalogue, ordinal_no, verdict, notes,
                                       chosen_source, chosen_name, data_rows, variants)
SELECT current_setting('mig.tenant_slug'), a.catalogue, a.ordinal_no,
       CASE WHEN a.n_types_data > 1  THEN 'CONFLICT_TYPE'
            WHEN o.name IS NOT NULL  THEN 'override'
            WHEN a.n_names_data > 1  THEN 'CONFLICT_NAME'
            WHEN a.n_names = 1       THEN 'same'
            WHEN a.n_names_data = 1  THEN 'named_by_data'
            ELSE                          'unused_differs' END,
       NULLIF(concat_ws(', ',
            CASE WHEN a.n_sources < p.n THEN 'partial' END,
            CASE WHEN a.n_types > 1 AND a.n_types_data <= 1 THEN 'types differ' END,
            'differ: ' || a.flag_cols), ''),
       c.source_schema,
       COALESCE(o.name, c.name),
       a.data_rows, a.variants
FROM agg a
CROSS JOIN payrolls p
JOIN chosen c USING (catalogue, ordinal_no)
LEFT JOIN migration.catalogue_override o
       ON o.tenant_slug = current_setting('mig.tenant_slug') AND o.catalogue = a.catalogue AND o.ordinal_no = a.ordinal_no;

-- ---- 2b. One name, several ordinals
-- The merge decides each ordinal on its own, so the SAME code sitting at
-- different ordinals in different payrolls (lodge 295 vs ho/matla 321 'ytd-ben
-- death') comes out as two ordinals with one name. Values stay on their ordinals,
-- but anything that finds a code BY NAME - E/D line labels, reports, people -
-- can no longer tell them apart. Blocking when two or more of those ordinals
-- hold values; a note when they do not (legacy itself carries a few unused
-- duplicates, and blocking those would stop a conversion for no reason).
WITH dup AS (
    SELECT catalogue, upper(btrim(regexp_replace(COALESCE(chosen_name, ''), '\s+', ' ', 'g'))) AS nkey,
           count(*) AS ordinals, count(*) FILTER (WHERE data_rows > 0) AS with_values,
           string_agg(ordinal_no::text, ',' ORDER BY ordinal_no) AS shared_with
    FROM migration.catalogue_merge
    WHERE tenant_slug = current_setting('mig.tenant_slug') AND btrim(COALESCE(chosen_name, '')) <> ''
    GROUP BY 1, 2 HAVING count(*) > 1)
UPDATE migration.catalogue_merge m
   SET verdict = CASE WHEN d.with_values > 1 AND m.verdict <> 'CONFLICT_TYPE' THEN 'CONFLICT_DUPLICATE_NAME' ELSE m.verdict END,
       notes   = concat_ws(', ', m.notes, 'name also at ' || d.shared_with)
  FROM dup d
 WHERE m.tenant_slug = current_setting('mig.tenant_slug') AND m.catalogue = d.catalogue
   AND upper(btrim(regexp_replace(COALESCE(m.chosen_name, ''), '\s+', ' ', 'g'))) = d.nkey;

-- ---- 3. Report
\echo
\echo '=== Catalogue merge: verdicts per catalogue ==='
SELECT catalogue,
       count(*) FILTER (WHERE verdict = 'same')           AS same,
       count(*) FILTER (WHERE verdict = 'named_by_data')  AS named_by_data,
       count(*) FILTER (WHERE verdict = 'unused_differs') AS unused_differs,
       count(*) FILTER (WHERE verdict = 'override')       AS override,
       count(*) FILTER (WHERE verdict LIKE 'CONFLICT%')   AS "CONFLICTS",
       count(*) FILTER (WHERE notes LIKE '%partial%')     AS partial
FROM migration.catalogue_merge WHERE tenant_slug = current_setting('mig.tenant_slug')
GROUP BY catalogue ORDER BY catalogue;

\echo '=== Every ordinal whose payrolls disagree (variants: payroll: [type] name [values held]) ==='
SELECT catalogue AS cat, ordinal_no AS ord, verdict, chosen_name AS becomes, notes, variants
FROM migration.catalogue_merge
WHERE tenant_slug = current_setting('mig.tenant_slug')
  AND (verdict <> 'same' OR notes LIKE '%differ%')
ORDER BY (verdict LIKE 'CONFLICT%') DESC, catalogue, ordinal_no;

\echo '=== Overrides that matched nothing (typo in catalogue-overrides.csv?) ==='
SELECT o.catalogue, o.ordinal_no, o.name
FROM migration.catalogue_override o
WHERE o.tenant_slug = current_setting('mig.tenant_slug')
  AND NOT EXISTS (SELECT 1 FROM migration.catalogue_merge m
                  WHERE m.tenant_slug = o.tenant_slug AND m.catalogue = o.catalogue AND m.ordinal_no = o.ordinal_no);

-- ---- 4. Apply (apply=1 only, and only with nothing blocking)
DO $$
DECLARE
    t   TEXT := current_setting('mig.tenant_slug');
    ts  TEXT := current_setting('mig.tenant_schema');
    bad TEXT;
BEGIN
    IF current_setting('mig.apply') <> '1' THEN
        RAISE NOTICE 'Report only (apply=0): the tenant was not touched.';
        RETURN;
    END IF;

    SELECT string_agg(catalogue || ' ' || ordinal_no || ' (' || verdict || ')', ', ' ORDER BY catalogue, ordinal_no)
      INTO bad FROM migration.catalogue_merge WHERE tenant_slug = t AND verdict LIKE 'CONFLICT%';
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'Unresolved catalogue conflicts: %. Name them in catalogue-overrides.csv (CONFLICT_TYPE needs a legacy renumber instead).', bad;
    END IF;

    EXECUTE format($q$
        INSERT INTO %I.settings_employee_amounts (ordinal_no, name, code_type, currency_code, code_limit_minor,
            tax_type, tax_inc_asn, consol_code, adjust_flag, manual_display, prorata, qmf_display)
        SELECT m.ordinal_no, m.chosen_name, s.code_type, s.currency_code, s.code_limit_minor, s.tax_type,
               s.tax_inc_asn, s.consol_code, s.adjust_flag, s.manual_display, s.prorata, s.qmf_display
        FROM migration.catalogue_merge m
        JOIN migration.catalogue_source s ON s.tenant_slug = m.tenant_slug AND s.catalogue = m.catalogue
                                         AND s.ordinal_no = m.ordinal_no AND s.source_schema = m.chosen_source
        WHERE m.tenant_slug = $1 AND m.catalogue = 'amounts'
        ON CONFLICT (ordinal_no) DO UPDATE SET name = EXCLUDED.name, code_type = EXCLUDED.code_type,
            currency_code = EXCLUDED.currency_code, code_limit_minor = EXCLUDED.code_limit_minor,
            tax_type = EXCLUDED.tax_type, tax_inc_asn = EXCLUDED.tax_inc_asn, consol_code = EXCLUDED.consol_code,
            adjust_flag = EXCLUDED.adjust_flag, manual_display = EXCLUDED.manual_display,
            prorata = EXCLUDED.prorata, qmf_display = EXCLUDED.qmf_display$q$, ts) USING t;

    EXECUTE format($q$
        INSERT INTO %I.settings_employee_alpha (ordinal_no, name)
        SELECT ordinal_no, chosen_name FROM migration.catalogue_merge WHERE tenant_slug = $1 AND catalogue = 'alpha'
        ON CONFLICT (ordinal_no) DO UPDATE SET name = EXCLUDED.name$q$, ts) USING t;

    EXECUTE format($q$
        INSERT INTO %I.settings_employee_dates (ordinal_no, name)
        SELECT ordinal_no, chosen_name FROM migration.catalogue_merge WHERE tenant_slug = $1 AND catalogue = 'dates'
        ON CONFLICT (ordinal_no) DO UPDATE SET name = EXCLUDED.name$q$, ts) USING t;

    EXECUTE format($q$
        INSERT INTO %I.settings_employee_precision_amounts (ordinal_no, name, code_type, limit_value)
        SELECT m.ordinal_no, m.chosen_name, s.code_type, s.limit_value
        FROM migration.catalogue_merge m
        JOIN migration.catalogue_source s ON s.tenant_slug = m.tenant_slug AND s.catalogue = m.catalogue
                                         AND s.ordinal_no = m.ordinal_no AND s.source_schema = m.chosen_source
        WHERE m.tenant_slug = $1 AND m.catalogue = 'precision'
        ON CONFLICT (ordinal_no) DO UPDATE SET name = EXCLUDED.name, code_type = EXCLUDED.code_type,
            limit_value = EXCLUDED.limit_value$q$, ts) USING t;

    RAISE NOTICE 'Merged catalogues written to %.', ts;
END $$;

COMMIT;
