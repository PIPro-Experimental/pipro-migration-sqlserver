-- ===========================================================================
-- migration_map — the small, human-decided routing config (config, not code).
--
-- The interim desktop DB splits its tables across TWO schemas per company
-- (hardcoded in the java): SchemaType.COMPANY = "airplane" and
-- SchemaType.PAYROLL = "pipro". Each map row routes one such PAIR of source
-- schemas -> one pipro tenant + payroll.
--
-- Assumes option (b) from the README: the interim schemas were dumped into
-- the docker DB, THEN the payroll one RENAMED to legacy_pipro. HARD LESSON
-- (2026-07-29): a schema named "pipro" shadows public for the app's database
-- USER "pipro" — postgres resolves unqualified names via search_path
-- "$user", public — and the app promptly rebuilt seed copies of its system
-- tables inside it, "losing" every real user/tenant row behind the shadow.
-- NEVER restore a schema whose name equals a database user name.
-- ===========================================================================

DROP TABLE IF EXISTS migration_map;
CREATE TABLE migration_map (
    legacy_company_schema TEXT PRIMARY KEY,  -- interim SchemaType.COMPANY schema in the docker DB
    legacy_payroll_schema TEXT NOT NULL,     -- interim SchemaType.PAYROLL schema in the docker DB
    tenant_slug           TEXT NOT NULL,     -- target: writes into tenant_<slug> (must already exist)
    target_payroll_id     INTEGER NOT NULL,  -- target: tenant_<slug>.payrolls.id (must already exist)
    legacy_payroll_number INTEGER NOT NULL DEFAULT 1  -- the interim Payroll number; fills the payroll
                                             -- scoping column on carried SchemaType.PAYROLL tables
                                             -- that had none (55_legacy_carry)
);

-- Live mapping (verified: interim payroll number = 1 everywhere, single
-- currency slot, basiccode = 1; tenant + payroll 1 provisioned).
INSERT INTO migration_map (legacy_company_schema, legacy_payroll_schema, tenant_slug, target_payroll_id, legacy_payroll_number) VALUES
    ('airplane', 'legacy_pipro', 'test_airplane', 1, 1)
ON CONFLICT (legacy_company_schema) DO NOTHING;
