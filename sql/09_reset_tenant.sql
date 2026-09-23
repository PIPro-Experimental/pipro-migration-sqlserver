-- ===========================================================================
-- 09_reset_tenant.sql — empty a tenant of ALL legacy-derived and run-generated
-- data, so an import can be a genuine full replacement rather than a top-up.
--
-- Runner variables:  :tenant_schema  :confirm   (:confirm must be the word RESET)
--
-- WHY THIS EXISTS (owner, 2026-09-22): importing from legacy is rare, and when
-- it happens the data has to come over in its ENTIRETY. Without this the import
-- only ever adds: 80_payroll_periods guards its insert with NOT EXISTS, the
-- slot loads use ON CONFLICT DO NOTHING, and 10_employees skips on a duplicate
-- employee_code. So a re-import over a populated tenant silently leaves the old
-- calendar and the old values in place, and the operator ends up hand-editing
-- what should have been replaced.
--
-- WHAT IT CLEARS
--   Every table in the tenant schema EXCEPT the keep-list below. That covers the
--   ~120 tables the import writes, plus anything a pay run generated (payslips,
--   previews, statutory rows, run headers, audit), plus employee-scoped tables
--   the import does not write but which would be ORPHANED by re-minting the
--   employees (leave_balances, leave_ledger).
--   It also removes the login users the import minted, which live in the shared
--   public.pipro_core_users - outside the tenant schema, so a schema-level wipe
--   would strand them - and this tenant's rows in the migration staging tables.
--
-- WHAT IT KEEPS: tenant CONFIGURATION, which provisioning and the country pack
--   created and which the legacy import knows nothing about. None of it is
--   employee-scoped. Emptying it would leave a tenant the app cannot run.
--
-- WHAT IT CANNOT DO: this is not a substitute for re-provisioning. It empties
--   data; it does not rebuild schema. If the module migrations themselves have
--   moved on, provision a fresh tenant through the app instead.
--
-- DESTRUCTIVE AND NOT REVERSIBLE. It refuses to run unless :confirm is RESET.
-- ===========================================================================
\set ON_ERROR_STOP on

-- psql does NOT substitute :variables inside a dollar-quoted $$...$$ body, so
-- they are handed to the block as session settings instead.
SELECT set_config('pipro.reset_tenant',  :'tenant_schema', false),
       set_config('pipro.reset_confirm', :'confirm',       false);

DO $$
DECLARE
    tenant  text := current_setting('pipro.reset_tenant');
    confirm text := current_setting('pipro.reset_confirm');
    -- Tenant configuration: provisioning + country-pack seed. Nothing here is
    -- employee-scoped and nothing here comes from legacy.
    keep    text[] := ARRAY[
        '__module_migrations',      -- the module migration ledger: wiping it breaks the tenant
        'payrolls',                 -- created through the app; target_payroll_id points at it
        'leave_types',              -- hrm-core seed
        'public_holidays',          -- country-pack seed
        'payroll_code_catalogue',   -- country-pack seed
        'payslip_line_settings',    -- payslip presentation config
        'calc_program'              -- country-pack calculation program
    ];
    r       record;
    n       bigint;
    cleared int := 0;
    kept    int := 0;
    minted  bigint[];
BEGIN
    IF confirm IS DISTINCT FROM 'RESET' THEN
        RAISE EXCEPTION 'Refusing to reset %: pass -v confirm=RESET to mean it.', tenant;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = tenant) THEN
        RAISE EXCEPTION 'No such tenant schema: %', tenant;
    END IF;

    -- Capture this tenant's employee user_ids BEFORE truncating. The minted users
    -- live in the shared public.pipro_core_users, so they must be identified by
    -- THIS tenant's employees - not by "has no tenant access", which would reach
    -- into other tenants' minted users too.
    EXECUTE format('SELECT array_agg(DISTINCT user_id) FROM %I.employees WHERE user_id IS NOT NULL', tenant)
       INTO minted;

    FOR r IN
        SELECT table_name FROM information_schema.tables
         WHERE table_schema = tenant AND table_type = 'BASE TABLE'
         ORDER BY table_name
    LOOP
        IF r.table_name = ANY(keep) THEN
            kept := kept + 1;
            CONTINUE;
        END IF;
        -- CASCADE because the tenant tables reference each other; RESTART IDENTITY
        -- so re-imported rows get the same ids they would in a fresh tenant.
        EXECUTE format('TRUNCATE TABLE %I.%I RESTART IDENTITY CASCADE', tenant, r.table_name);
        cleared := cleared + 1;
    END LOOP;

    RAISE NOTICE 'Tenant %: % tables cleared, % configuration tables kept.', tenant, cleared, kept;

    -- Only users this tenant's employees pointed at, and only those carrying the
    -- unusable password 10_employees mints them with - so a real operator account
    -- that happens to also be an employee, and the seeded demo users, survive.
    DELETE FROM public.pipro_core_users u
     WHERE u.id = ANY(COALESCE(minted, ARRAY[]::bigint[]))
       AND u.password_hash = '!migrated-no-login';
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'Removed % minted login users.', n;

    -- Migration staging for this tenant only; other tenants keep theirs.
    -- The column MUST be qualified: 'tenant' is also the plpgsql variable above,
    -- and unqualified plpgsql would substitute the variable on both sides, making
    -- the predicate always true and wiping every tenant's staging rows.
    DELETE FROM migration.ytd_takeon y WHERE y.tenant = tenant;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'Removed % ytd_takeon staging rows.', n;

    DELETE FROM migration.amount_quarantine q WHERE q.tenant = tenant;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'Removed % quarantined amount rows.', n;
END $$;

\echo ''
\echo '=== Tenant after reset - anything non-zero here is configuration ========='
SELECT table_name,
       (xpath('/row/c/text()', query_to_xml(
            format('SELECT count(*) AS c FROM %I.%I', :'tenant_schema', table_name),
            false, true, '')))[1]::text::bigint AS rows
FROM information_schema.tables
WHERE table_schema = :'tenant_schema' AND table_type = 'BASE TABLE'
ORDER BY 2 DESC, 1
LIMIT 15;
