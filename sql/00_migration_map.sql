-- ===========================================================================
-- migration_map — the small, human-decided routing config (config, not code).
--
-- Keyed on the LEGACY SOURCE SCHEMA, because on the desktop DB each SQL Server
-- company was imported into its own schema (your "specify different schemas"
-- point). Each row routes one source schema -> one pipro tenant.
--
-- Assumes option (b) from the README: the legacy tables were dumped into the
-- docker DB as schemas named <legacy_schema> (e.g. legacy_acme), so hop 2 is a
-- single-DB script. YOU fill these in — you know which legacy company IS acme.
-- ===========================================================================

CREATE TABLE IF NOT EXISTS migration_map (
    legacy_schema      TEXT PRIMARY KEY,  -- source schema in the docker DB (e.g. legacy_acme)
    tenant_slug        TEXT NOT NULL,     -- target: writes into tenant_<slug> (must already exist)
    target_payroll_id  INTEGER NOT NULL   -- target: tenant_<slug>.payrolls.id (must already exist)
);

-- DECISION: seed your real mappings.
INSERT INTO migration_map (legacy_schema, tenant_slug, target_payroll_id) VALUES
    ('legacy_acme',   'acme',   1),
    ('legacy_globex', 'globex', 1)
ON CONFLICT (legacy_schema) DO NOTHING;
