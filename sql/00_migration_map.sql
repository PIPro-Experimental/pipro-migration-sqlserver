-- ===========================================================================
-- migration_map — the small, human-decided routing config (config, not code).
--
-- The interim desktop DB splits its tables across TWO schemas per company
-- (hardcoded in the java): SchemaType.COMPANY = "airplane" and
-- SchemaType.PAYROLL = "pipro". Each map row routes one such PAIR of source
-- schemas -> one pipro tenant + payroll.
--
-- Assumes option (b) from the README: the interim schemas were dumped into
-- the docker DB under their own names (pg_dump -n airplane -n pipro |
-- restore), so hop 2 is a single-DB script. Neither name collides with the
-- target layout (public + tenant_<slug>).
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

-- DECISION: seed your real mapping (tenant_slug must be a provisioned tenant).
INSERT INTO migration_map (legacy_company_schema, legacy_payroll_schema, tenant_slug, target_payroll_id, legacy_payroll_number) VALUES
    ('airplane', 'pipro', 'airplane', 1, 1)
ON CONFLICT (legacy_company_schema) DO NOTHING;
