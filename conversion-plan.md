# Converting a client from Paywell to pipro

How a real client conversion runs, what has to be true before it starts, and what
is built versus still to build. Written 2026-09-23 from the airplane/test_airplane
work; the numbers quoted are from that client unless stated.

The single-payroll rehearsal is documented in `README.md`. This covers the shape
a real client takes: several payrolls, and optionally years of history.

---

## 1. The shape

| Legacy | pipro |
|---|---|
| One SQL Server **database** per payroll | One **row** in `payrolls` |
| ~10 databases for a 10-payroll client | **One tenant, one schema**, ten payroll rows |
| `PW_IMF.EmpNo`, unique within a **database** | `employees.employee_code`, unique within the **tenant** |

A client is one tenant. A tenant is one schema (`tenant_<slug>`, currently 160
tables). Many tenants share a database, each in its own schema — splitting across
databases or instances is a load decision, not a modelling one.

Each import unit is one row in `migration_map`
`(legacy_company_schema, legacy_payroll_schema, tenant_slug, target_payroll_id, legacy_payroll_number)`.
Ten payrolls is ten rows against the same `tenant_slug`.

> **`employee_code` must be qualified for a multi-payroll client.** `employees` has
> `UNIQUE (employee_code)` across the whole tenant, but legacy only ever guaranteed
> `EmpNo` unique *within* a payroll — global uniqueness was of the `(Payroll, EmpNo)`
> pair. So payroll 1's employee 57 and payroll 3's employee 57 collide, and
> `10_employees` ends with `ON CONFLICT (employee_code) DO NOTHING`, which would
> **silently skip** the second payroll's employees. Qualify it — `<payroll>/<empno>` —
> which is safe because `employee_code` is user-facing and editable. `90_employee_map`
> section 2 catches the collision, but after the fact; don't rely on it.
>
> **The same applies to the synthesised email.** `pipro_core_users.email` is
> UNIQUE across the installation, and `10_employees` synthesises
> `<empno>@migrated.invalid` where the legacy address is blank — so two payrolls
> each holding an employee 57 collide there too. That one does not skip a row, it
> **fails the whole import**, because step 2 mints users with a plain `INSERT`.
> It is now qualified the same way. What qualification cannot fix is two
> employees sharing a **real** address across payrolls, which would fail
> identically — worth checking before a multi-payroll run.

Per payroll the data travels:

```
SQL Server database
  -> PostgresImport (java)      -> interim Postgres: one COMPANY + one PAYROLL schema
  -> refresh-interim.ps1        -> docker Postgres, same pair
  -> sql/09..80                 -> tenant schema
```

---

## 2. What the client has to send

**Required:** one backup per payroll database.

**Optional:** the year-end archives. Legacy has no real history store, so at each
tax-year end the client backed up `xx` and restored it as `xx_2025`, `xx_2024` and
so on. Under the retention rule in §7 you only ever need the **last five tax
years**, so ask for those and no more.

**Not required:** the `PayCatalogue` database. It holds `DatabaseCatalog` (the
list of payroll databases and their client names — this is where the schema name
comes from) and `Global_Employee` (every employee of every payroll, keyed
`(Payroll, EmpNo)`, carrying `IDNum`, `Surname`, `BirthDate`, `EngageDate`,
`TermDate`).

`DatabaseCatalog` is genuinely useful: it can seed the manifest in §3 instead of
someone typing ten database names. `Global_Employee` is **not** load-bearing —
cross-payroll identity is resolved from the payroll data itself (§6), so nothing
depends on the client having sent it, or on it having been populated.

> If you ever do want `Global_Employee` rebuilt, `Pay427` syncs one payroll into
> it — but it **deletes every row whose EmpNo is absent from the current IMF**
> before upserting. So it reconstructs current state only, and running it over a
> client-supplied catalogue silently downgrades a historical registry to a
> snapshot. Back one up before touching it.

---

## 3. The manifest

One row per import unit, in a gitignored `payrolls.csv` beside
`settings.local.txt`:

```
source_db, company_schema, payroll_schema, tenant_slug, target_payroll_id, legacy_payroll_number, role, tax_year
xx,        xx_co,          xx_pay,         acme,        1,                  1,                     current,
xx_2025,   xx25_co,        xx25_pay,       acme,        1,                  1,                     history, 2025
```

`settings.local.txt` keeps connection details; the manifest keeps what varies per
payroll. Nobody edits a script or a schema name between runs.

**The manifest is a declaration to be verified, not an instruction to be trusted.**
Every value a human typed is checked against the data before anything is written:

| Check | Catches |
|---|---|
| declared `tax_year` vs the year derived from the data | a mislabelled backup |
| each derived tax year appears exactly once | the same archive imported twice |
| derived tax years are contiguous | a missing year |
| `(payroll, run_year, run_period)` already in the target | a re-import, at the data level |

The tax year is derived, never read from the database name:
`min(PW_RunH.RunDate)` gives the March that opens the year, and
`PW_Parm_GlobalSystem.CurrentRunDate` gives the last run in that database.

The last check is the real guard — it doesn't care about names, manifests or
operator error, and stops a double-import cold even if the first three were
bypassed.

---

## 4. Current-state conversion, per payroll

1. Restore the payroll database to SQL Server.
2. Run PostgresImport against it.
3. `refresh-interim.ps1` — copies **both** interim schemas into docker under the
   manifest's names. Both, always: the calendar that drives `payroll_periods`
   lives in the payroll schema, and refreshing only the company one leaves the
   calendar stale.
4. `sql/09_reset_tenant.sql` on the first payroll only — see below.
5. `run-migration.ps1` — runs `10/20/40/50/55/60/70/80` for each `migration_map`
   row.

**Reset semantics.** An import from legacy is a full replacement, not a top-up:
`80_payroll_periods` guards with `NOT EXISTS`, the slot loads use
`ON CONFLICT DO NOTHING` and `10_employees` skips on duplicate `employee_code`,
so without a reset a re-import silently leaves the old calendar and old values in
place. `09_reset_tenant.sql` empties everything employee- or run-scoped and keeps
the seven configuration tables provisioning created.

It resets **the tenant**, so for a multi-payroll client it runs **once**, before
the first payroll — not per payroll, or each one would wipe its predecessors.

---

## 5. Historical conversion

Only three families come across, and they never replace current data:

| Family | Span in a database | So |
|---|---|---|
| `PW_RunH*` | current tax year only | import from **every** archive; they're disjoint |
| `PW_PH*` (payslips) | current tax year only | same |
| `PW_LeaveHistory2` | all years, never purged | import from the **newest source only** |

Verified on this client: run and payslip history covered 2026 only — 748 rows =
4 periods × 187 employees, payslip dates 2026-03-01…06-30 — while leave history
spanned roughly 2001–2026. So the overlap problem is confined to leave history,
and it's solved by choosing one source rather than by deduplication.

Employees present in an archive but gone from the current payroll import come in
**terminated**, and age out on the ordinary retention rule. No new concept, and
it's the same path whether the data arrived by import or by the system running
for five years.

### The historical path does not need PostgresImport

The interim stage exists because PostgresImport does real work — type conversion,
table remapping, codetype routing. A historical *discharged* employee needs none
of it. `employees` has only nine NOT NULL columns
(`id, user_id, employee_code, first_name, last_name, hired_at,
salary_current_minor`, `currency`, `created_at`), and `PW_IMF` carries all of it
directly: `EmpNo, Payroll, Surname, Inits, GivenNames, BirthDate, EngageDate,
DischDate`. The ID number comes from `PW_RefNos` ordinal 1.

The only conversions needed — the 1799-12-31 day-number date epoch, the
refno/RefNoCode promotion, float rounding — are **already implemented** in
`export-legacy.ps1` and `sql/93_legacy_snapshot.sql` for the comparison reports.

So the historical import reads SQL Server **directly** (`PW_IMF`, `PW_RefNos`,
`PW_RunH*`, `PW_PH*`), with no PostgresImport run and no interim schemas per
archive. That is the whole reason the archives are cheap to process.

### Leave history: one source, imported last

Leave history is never purged, so the **live** database holds every row including
those belonging to employees long since deleted from its own `PW_IMF` — 5,725 of
8,920 on this client. The archives add nothing.

So leave still comes from the live database only, but the **ordering matters**:
import it *after* the historical employees exist, so rows that were orphaned
against live's master file can attach to the reinstated employee. Anything still
orphaned after that belongs to someone who left before the retention window, and
would be pruned anyway.

Leave is not merely an audit nicety — accrued leave is a liability, and the BCEA
requires records of leave taken. It belongs in the statutory set.

---

## 6. Identity

**Within a payroll:** the spine is `employee_code` = legacy `EmpNo`. This is
already proven — the key is re-minted twice on the way through
(legacy `EmpNo` → interim auto-key → pipro `users.id`) and `employee_code` is the
only value that survives both. Never join on `'emp-' || <legacy EmpNo>`.

**Across payrolls:** the same person who moved between payrolls has two employee
records with different `EmpNo`s. Match them on **ID number + surname**. If the
match fails, the two records stand as two employees — that is an accepted
outcome, not an error to escalate.

**Leave history predating the engage date is rejected, not imported.** On this
client **1,706 of the 3,195 importable leave rows are dated before the engage date
of the employee they attach to** — either a previous holder of a reused `EmpNo`,
or the same person's *earlier* employment episode. Both are rejected, and the
reasoning holds either way: a reused number means the row belongs to someone else,
and a closed earlier episode had its balances settled at termination and falls
outside the retention window regardless.

So legacy leave is read with the employee joined in and the date bounded:

```sql
SELECT E.EmpNo, L.Code, L.LeaveType, L.FromDate, L.ToDate
FROM   PW_IMF E
JOIN   PW_LeaveHistory2 L ON L.EmpNo = E.EmpNo
WHERE  L.FromDate > E.EngageDate
```

That takes this client from 3,195 rows to **1,489**. (`>` versus `>=` makes no
difference here — nobody took leave on their engage date.)

Two notes on that filter. An outer join does not survive a `WHERE` on the right
table, so it must be an inner join — writing `LEFT JOIN` reads as though unmatched
employees are kept, and they are not. And the employee set should be *the
employees being loaded*, not `PW_IMF` alone: a leaver reinstated from an archive
has leave in the live database that `PW_IMF` no longer knows about. On this client
that distinction is moot — **zero** orphaned leave rows fall inside the five-year
window — but it will not be moot for a client with recent leavers.

**Two conditions make identity matching meaningless**, and the verification must
say so rather than reporting confident nonsense:

- **Generated ID numbers.** The interim `id8001` job mints valid SA IDs from the
  date of birth with the sequence pinned to its upper bound, so they are
  recognisable at **positions 7–12 = `499909` or `999909`** (only the checksum
  digit varies — a test on the last six characters is wrong). Every ID in the
  test client is generated, which is why two employees there share an ID: same
  birth date, same gender.
- **Scrubbed surnames.** POPIA pseudonymisation replaces the surname with a
  64-character hash. Seventeen employees in the test client are in this state.

Both are artifacts of preparing a live client's data for testing. A real
conversion imports unscrubbed data and runs pipro's own scrubbing **after the
whole backup set is in** — which is also the only order in which surname matching
can work.

---

## 7. Retention

**Five years, all data, active and terminated.** Above both the SARS five-year
payroll requirement and the BCEA three-years-past-termination one, and defensible
under POPIA minimisation in a way that keeping twenty-five years of leave detail
for a current employee is not.

Two consequences:

- **Apply it at import.** Importing twenty-five years and pruning twenty the next
  day is pointless. This is what bounds the archive set to five tax years.
- **It is safe.** `leave_balances` is a base table with a stored
  `balance_centidays` — balances do not derive from history, so pruning history
  cannot corrupt one.

Make the window a **per-tenant setting**, not a constant.

**Gap:** anything reasoning about length of service must not read
`employee_contracts.hired_at`. An engage date belongs to one contract, so a person
with twenty years' service across three payrolls has three engage dates. Clients
keep the *original* engage date in a client-configured **dates-bank ordinal**, so
pipro needs a configured pointer to it — the same shape as
`settings_taxcodes.basic_code`. That pointer does not exist yet.

---

## 8. Verification

Three reports, all read-only apart from the `compare` schema.

- **`compare_report.cmd [before|after]`** — employee master data, legacy vs
  experimental. A difference here is an import defect.
- **`run_report.cmd [live|validation] [period]`** — run output, legacy vs
  experimental. A difference here is the two engines disagreeing. Gated so that
  an empty side, differing master data or mismatched row counts report a summary
  instead of thousands of rows.
- **Historical verification — still to build.** It should assert: the employee
  resolution rate (matched, orphaned, matched via surname, blocked by a scrubbed
  surname); that each archive contributed exactly its own tax year; that leave
  history came from one source only; and **how many leave rows were rejected for
  predating the engage date** (§6) — 1,706 on this client, a number worth watching
  because a sudden jump means either `EmpNo` reuse or a bad engage date.

**Legacy row counts are not a valid target.** This client has 8,920 leave-history
rows of which 5,725 belong to employees long since deleted from `PW_IMF` —
legacy has no referential integrity and nothing ever swept them. The import
carried all 3,195 rows that had an employee, which is correct. A report claiming
"64% lost" would be wrong.

---

## 9. Known gaps

| Gap | Effect |
|---|---|
| `PostgresImport` hardcodes the schema pair (`airplane`/`pipro`) | ten payrolls need renaming gymnastics on every run |
| The desktop Postgres staging hop | a second database to keep in sync; already caused two stale-copy failures |
| No original-engage-date pointer in pipro | length-of-service logic has nothing correct to read |
| Identity logic unvalidatable on this dataset | needs a clean client dataset or synthetic fixtures |
| `employee_code` not qualified by payroll | second payroll of a multi-payroll client silently skipped |
| `payrolls.csv` manifest + multi-payroll driver | not built |
| Historical import and its verification | not built |

The first two have one fix between them: point `PostgresImport` at the docker
Postgres and make the schema pair configurable. That deletes the desktop hop,
`refresh-interim.ps1` and the pg18→pg16 mismatch, and removes the entire class of
"the copy was stale" failures rather than adding more checks for them. Two changes
to the java, and the pipeline collapses to:

```
SQL Server -> PostgresImport -> docker schemas -> tenant
```

---

## 10. What exists today

| Script | Does |
|---|---|
| `refresh-interim.ps1` | both interim schemas → docker, payroll one renamed in one transaction |
| `sql/09_reset_tenant.sql` | empties a tenant; keeps seven config tables; refuses without `confirm=RESET` |
| `sql/10..80` + `run-migration.ps1` | the import chain, driven by `migration_map` |
| `sql/90_employee_map.sql` | durable key bridge + import-integrity report |
| `sql/91/92` + `compare_report.cmd` | employee master parity |
| `sql/93` + `export-legacy.ps1` | legacy master extract |
| `sql/95/96` + `export-legacy-run.ps1` + `run_report.cmd` | run-output parity |

Built for one payroll, no history. Everything in §3, §5 and the historical half of
§8 is still to write.
