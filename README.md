# pipro-migration-sqlserver (hop 2 — schema modernization)

**Scaffold / prototype — not wired into the app, not compiled.** This delivers
*hop 2* of the two-hop migration:

```
SQL Server ──(hop 1: PostgresImport, unchanged)──▶ desktop Postgres (iteration-2 / DataDictionary schema)
                                                          │
                                                          ▼
                              hop 2 (THIS repo): SQL scripts, per tenant, via search_path
                                                          │
                                                          ▼
                                      docker Postgres (iteration-3 / pipro schema)
```

## Division of ownership (why this can stay pure SQL)

- **The pipro app creates & registers the tenant schema.** Provision each tenant
  through the app's tenant-admin path FIRST, so `tenant_<slug>` exists with all 44
  tables at the current migration version, and `public.pipro_core_tenants` is
  populated. These scripts never `CREATE` a tenant schema or touch migration state.
- **A payroll must exist too.** `employee_payroll_assignments.payroll_id` is a FK to
  `tenant_<slug>.payrolls` (both tenants ship with it EMPTY). Create the payroll via
  the app, then put its real `id` in `migration_map.target_payroll_id`.
- **These scripts only POPULATE an already-provisioned tenant schema**, chosen at
  run time via `search_path` — so the script body is schema-agnostic and you run it
  once per tenant.

## Run order

1. `sql/00_migration_map.sql` — routing config (edit the seed rows).
2. `run-migration.ps1` — per tenant: `sql/10_employees.sql` (users → employees →
   contracts → assignments → status) then `sql/20_recurring.sql` (recurring
   earnings/deductions). Docker-preflight; each file is one transaction (rolls back on error).

## Validation status (2026-07-09)

The **target side is proven**: all 7 destination tables (`pipro_core_users`,
`employees`, `employee_contracts`, `employee_payroll_assignments`,
`employee_status_history`, `employee_recurring_earnings/deductions`) were exercised
with synthetic rows against the live schema inside a rolled-back transaction — every
INSERT's columns/types/constraints check out. What remains is the **source side**:
the `-- DECISION` mappings + confirming the legacy column names against your desktop DB.

## Getting the legacy data reachable

> **Cross-DB note:** hop 2 reads from desktop Postgres and writes to docker Postgres —
> two different servers. Options: (a) `postgres_fdw` foreign tables (shown in
> `10_employees.sql` header), or (b) dump the legacy tables and `\copy` them into a
> `legacy` schema in the docker DB, then this is a single-DB script. The runner assumes (b).

## What is REAL vs. what YOU must confirm

- ✅ **Target columns/types/constraints** — taken verbatim from the hrm-core migrations
  (`employees`, `employees_modernise`, `employee_contracts`). These are correct.
- ⚠️ **Source column names** — taken from `petervm_pipro_java/.../DataDictionary.java`
  (`Surname_F02`, `EngageDate_D931`, …). Confirm against YOUR desktop DB — the exact
  names depend on how PostgresImport materialised them.
- ⚠️ Every `-- DECISION:` comment marks a mapping choice only you can make.

## The two real complications this scaffold handles

1. **Identity.** The operational link key across tenant tables is the **integer
   `user_id`** (the engine reads `employees WHERE user_id=?` and `employee_contracts
   WHERE employee_id=?` with the same integer). So each employee needs a
   `public.pipro_core_users` row first; its generated id becomes the link. Handled via
   an `_idmap` staging table (legacy EmpNo → new user_id).
2. **Bitemporal fan-out.** One legacy masterfile row → one `employees` row + one
   effective-dated `employee_contracts` row (rate from the legacy BASIC amount line).
   `effective_from` = the employee's engage date; `recorded_at` = the migration cutover.
