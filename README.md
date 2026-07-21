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
   contracts → assignments → status) then `sql/20_recurring.sql` (routes ALL
   `employee_amounts` by codetype). Docker-preflight; each file is one transaction.

## Amount routing by codetype (`20_recurring.sql`)

`employee_amounts` is routed by its `codetype` (from `settings_employee_amounts` /
legacy `pw_parm_codes`) — **nothing is silently dropped**:

| codetype | routed to |
|---|---|
| `E` earning | `employee_recurring_earnings` |
| `D` deduction | `employee_recurring_deductions` |
| `C` cost-to-company | `employee_employer_cost` |
| `Y` YTD total | `migration.ytd_takeon` (mid-year staging) |
| other recognised (`T H S J B …`) | `employee_deprecated_amounts` — **LIVE, `Q`-addressed, phase-out** |
| codetype not found (no catalogue row) | `migration.amount_quarantine` |
| orphan (employee didn't load) | `migration.amount_quarantine` |

The catalogue (`settings_employee_amounts`, **all** codes incl. `J`) is imported to the
pipro `settings_employee_amounts` table. Cost / deprecated / catalogue values **keep their
`OrdinalNo` and stay `Q`-addressed**, so calc/payslip/report references never change (the
physical split is invisible above the loader).

### Codetype legend (VB6 + live-DB grounded, 2026-07-16)

Codetypes are **data-driven** (read straight from `settings_employee_amounts.codetype`);
the code only special-cases specific letters. The quarantine report is the authoritative
inventory per client. Confirmed meanings + eventual homes:

| codetype | meaning | eventual pipro home |
|---|---|---|
| `E` | earning | `employee_recurring_earnings` ✅ done |
| `D` | deduction | `employee_recurring_deductions` ✅ done |
| `Y` | YTD total (cleared at year-end) | `cumulative_ledger`/`payslip_fact` (mid-year take-on) — staged |
| `C` | cost-to-company (employer cost) | `employee_employer_cost` ✅ |
| `T` | time worked (decimal; std/1.5×/2×) | `employee_deprecated_amounts` (phase-out) |
| `H` | hours (as `T`, HH:MM; minutes<60) | `employee_deprecated_amounts` (phase-out) |
| `J` | a `DDMMYY` date stuffed into an amount — dormant, calc-unsafe | `employee_deprecated_amounts` — **unsupported**; a calc that hits one treats it as an amount or logs+skips |
| `S` | scratch/working value | `employee_deprecated_amounts` (phase-out) |
| `B` | **balances — heterogeneous "junk drawer"** (see below) | classify **per code**, not per codetype |
| `I` | — | not present in the live DB checked; treat as non-existent |

**`B` is not one category** — the codetype only says "balance"; it must be classified
**per code**. Subtypes + fates (rate model simplified per owner decision 2026-07-16:
a single Basic rate, `monthly|daily|hourly`; overtime *derives*, e.g. double-time = 2×Basic
— independent OT/variant/per-employee rates are NOT carried):

| `B` subtype | e.g. | fate |
|---|---|---|
| age (derived each run) | AGE | **drop** — pipro recomputes from `date_of_birth`; birthday message = template on DOB |
| leave | sick / annual / study | `leave_balances` / `leave_ledger` |
| basic rate | monthly/daily/hourly | `employee_contracts.rate_minor` (single Basic) |
| OT / variant rates | 1.5× / 2× / per-emp hourly | **drop** — OT derives from Basic |
| financial carry-forward | b/f & c/f gross/rate, std tax income | `cumulative_ledger` (take-on) |

All `B` currently quarantines (nothing lost); classifying each `B` code to a fate above is
the follow-up (57 `B` codes seen in one live DB).

The `migration.*` report tables are **persistent** — after a run, query them to see exactly
what each codetype carries per client (the forcing function). **Follow-ups:** (1) materialise
`migration.ytd_takeon` into `cumulative_ledger`/`payslip_fact` — needs a legacy-Y-code → pipro
aggregate-code map + a per-period vs opening-balance decision (only matters for
`tax_method='cumulative'` payrolls); (2) build the per-code `B` classification map (age→drop, leave→`leave_balances`, basic rate→
`employee_contracts`, OT→drop/derive, carry-forward→`cumulative_ledger`);
(3) decide a home for `C` (cost-to-company).

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

## Two routes for the employee master load

There are two ways to get employees in, and they trade off fidelity vs. safety:

**A. Direct SQL** (`10_employees.sql` + `20_recurring.sql`) — raw INSERTs. Full fidelity
(any number of recurring lines, any column), fast, but **DB-constraints-only validation,
no audit trail, and 10/20 are separate transactions** (a failed parent in 10 can orphan
children in 20).

**B. App importer** (`30_export_employee_import_csv.sql` → upload) — generate the CSV the
`EmployeeImportController` expects, feed it through the app. You get **row-level validation
(required/format/in-batch dedup), correct per-employee user minting, an audit trail, and
parent+child atomicity** (one CSV row = user + employees + all child rows in ONE
transaction; a rejected row writes NOTHING — no orphans). But it models the **common case
only**: recurring lines are FIXED named slots (travel/housing/cell allowances;
retirement/medical deductions) — it does **not** represent arbitrary legacy amount codes,
and it only pulls columns that have a declared `ImportableField`.

**Recommended (given ≤1000 employees/payroll — efficiency is a non-issue):** load the
**master + one-per-employee children via route B** (validation + audit + atomicity), then
**top up any non-standard recurring lines via route A** (`20_recurring.sql`). Route B alone
is NOT full coverage; plan for the top-up if employees carry recurring codes beyond the
fixed slots.

## What is REAL vs. what YOU must confirm

- ✅ **Target columns/types/constraints** — taken verbatim from the hrm-core migrations
  (`employees`, `employees_modernise`, `employee_contracts`). These are correct.
- ⚠️ **Source column names** — taken from `petervm_pipro_java/.../DataDictionary.java`
  (`Surname_F02`, `EngageDate_D931`, …). Confirm against YOUR desktop DB — the exact
  names depend on how PostgresImport materialised them.
- ⚠️ Every `-- DECISION:` comment marks a mapping choice only you can make.

## Identity model (how pipro keys employees — and where it differs from legacy)

In the legacy/interim system a **user** (operator, who runs payroll) and an
**employee** (a payroll resource) were *separate, unlinked* concepts — most users
were also employees, but nothing joined them. **pipro links them.** Every employee
carries a `user_id` (NOT NULL) so it can self-service (ESS). There are three keys:

| pipro key | type | role | legacy analog |
|---|---|---|---|
| `pipro_core_users.id` | `bigint`, auto-identity | a **system user / login** (your "operator"). pipro's PAYROLL tables (contracts, assignments, payslips, the engine) identify the employee **by this id**. | your operator id — but pipro forces one per employee |
| `employees.id` | `text` (app: random hex; scaffold: `emp-<EmpNo>`) | opaque record PK; used only by hrm self-refs (`manager_id`, org-unit head) | none (new) |
| `employees.employee_code` | `text` UNIQUE | the **human-facing code** | your `EmployeeId_F01` |

**Migration consequences:**

1. **We MINT a login-user per employee** (unusable password) because `user_id` is
   NOT NULL — a link the legacy world never made. This is *not* the migration of your
   legacy operator accounts; that's a separate job, and an operator who is also an
   employee may need de-duping later.
2. **The bridge is `EmployeeNo` → new `user_id`** (via the `_idmap` staging table).
   Your interim integer `EmployeeNo` (which the child tables keyed on) does **not**
   survive as a pipro key — pipro mints its own. The scaffold preserves it inside
   `employees.id` (`emp-<EmpNo>`) purely for traceability.
3. **`EmployeeId_F01` → `employee_code`** carries the user-facing continuity, exactly
   as in your interim system (numeric now, alpha later — pipro stores TEXT).

## The other complication: bitemporal fan-out

One legacy masterfile row → one `employees` row + one effective-dated
`employee_contracts` row (rate from the legacy BASIC amount line).
`effective_from` = the employee's engage date; `recorded_at` = the migration cutover.
