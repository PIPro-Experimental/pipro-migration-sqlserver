# PiPro Engine — Payroll Run Data-Flow Reference

> Traces the tables the **pipro-engine** (Java calc VM) reads as run inputs, the
> JSON it returns, the PHP that receives and persists it, and the tables those
> results land in — with the tie-back to the legacy SQL Server / `petervm_pipro_java`
> schema. Verified against the code (file:line) on 2026-07-09. **Analysis only —
> no code was changed.**

## Schema iterations (context)

1. **SQL Server** — the original legacy system (`PW_IMF` masterfile, `PW_Tranf`
   transaction file, `PW_Parm_*` parameter tables). Still the system of record.
2. **MySQL port + aggressive cleanup** — captured in
   `petervm_pipro_java/.../DataDictionary.java`: dropped/renamed to intuitive names
   (`employees`, `employee_amounts`, `payslip_history_*`, `run_history*`, `settings_*`).
3. **This experimental pipro system** — normalized, schema-per-tenant, kernel-module
   design. Employee data split across `employees` + `employee_*` tables; run outputs
   across `payslips_core` + `payslip_*` + `payroll_runs` + `payslip_fact`.

All iteration-3 tables below live in the **tenant schema** (`tenant_acme`,
`tenant_globex`, …), schema-qualified at runtime as `%1$s` via `TenantSchemaName`.

## The run flow

```
                    ┌──────────────────────── INPUTS (reads) ─────────────────────────┐
pipro-engine  ◀─────┤ PostgresRunInputLoader.java — 15 tenant tables, as-of-payday     │
   │                └──────────────────────────────────────────────────────────────────┘
   │  computes payslips in the VM
   ▼
/v1/run  ──JSON (EngineRunResult)──▶  EngineRunClientContract        (payroll-core: HTTP client, HMAC, deserialize)
                                            │
                                            ▼
                                  ZaEngineRunController.php           (payroll-za: RECEIVES the JSON)
                                    :128  $run = $this->engineRun->run(slug, payrollId, payday, runId)
                                    :134  $this->persister->persist(periodId, $run, now)
                                            │
                 ┌───────────────────────────┼─────────────────────────────────────┐
                 ▼                            ▼                                       ▼
        ZaEngineRunPersister       ZaRunStatutoryPostProcessor          ZaPayslipFactProjector
        (payslip header+lines+     (negative-balance carry)             → PayslipFactWriter
         statutory)                                                     → CumulativeLedgerRebuilder
```

The engine is **stateless**: it does not write to the DB (the old `RunResultWriter`
was deleted). It reads inputs, returns JSON; **PHP owns all persistence.** ZW mirrors
ZA via `ZwEngineRunController` → `ZwEngineRunPersister`.

---

## INPUT tables — what the engine reads

All in `pipro-engine/src/main/java/com/pipro/engine/run/PostgresRunInputLoader.java`.
"As-of-payday" = bitemporal `DISTINCT ON (…)` by `(effective_from, recorded_at, id)`
effective on/before payday.

| # | iteration-3 table (tenant) | What the engine reads | file:line | Legacy SQL Server | iteration-2 (`DataDictionary`) |
|---|---|---|---|---|---|
| 1 | **employee_payroll_assignments** | worklist: employees on this payroll, as-of-payday; also SDL annual basis | 54, 835 | `PW_IMF` (payroll assignment) | `employees.Payroll_F04` / `payrolls` |
| 2 | **payroll_transactions** | worklist UNION half (pending holders) + per-period once-off input lines (override / part-payment / variable / time / manual) | 79, 745 | `PW_Tranf_A` / `PW_Tranf` | `transactions`, `transactions2`, `transaction_a` |
| 3 | **payroll_periods** | period id, payday, `period_kind`, `interim_recovery` (run type) | 80, 131, 145 | run calendar / period control | `settings_calendar`, `settings_payroll_dates` |
| 4 | **payrolls** | `tax_method` (cumulative vs non-cumulative) | 120 | `PW_Parm_Calculations` (per-payroll) | `payrolls`, `settings_calculations` |
| 5 | **employees** | first_name, last_name, employee_code, date_of_birth (age → PAYE rebate) | 177 | `PW_IMF` masterfile | `employees` (monster table) |
| 6 | **employee_contracts** | monthly `rate_minor` (BASIC), `currency`, as-of-payday | 161, 181, 839 | `PW_IMF` rate F-codes | `employees` rate fields |
| 7 | **calc_program** | program-as-data VM instructions (ADR-0019), per `program_key` = `payroll-<id>` → `default` → `SalaryOnlyProgram` | 515 | `PW_Parm_Calculations` | `settings_calculations` |
| 8 | **employee_recurring_earnings** | recurring earning lines (label, amount, taxable, uif, payroll_code) | 625, 639 | `PW_IMF` earning fields | `employee_amounts`, `settings_employee_amounts` |
| 9 | **employee_recurring_deductions** | recurring deduction lines (label, amount, reduces_taxable, payroll_code) | 664, 683 | `PW_IMF` deduction fields | `employee_amounts` |
| 10 | **payroll_code_catalogue** | addable code templates: inclusion_fraction, subject_to_uif, reduces_taxable, sars_code | 573, 597, 665 | `settings_taxcodes` / `AddTaxCode` | `settings_taxcodes`, `settings_calculations` |
| 11 | **employee_loans** | active in-term loans → coded `LOAN` post-tax deduction | 702 | third-party / loan masterfile | `employee_thirdparty_transact` |
| 12 | **employee_status_history** | status as-of-payday (active/suspended/terminated → payable gate) | 811 | `PW_IMF` status/discharge F-codes | `employees` status fields |
| 13 | **employee_medical_aid** | is_primary_member, dependants_count (§6A medical credit) | 823 | `PW_IMF` medical fields | `employees` / `settings_*` |
| 14 | **cumulative_ledger** | YTD accumulators (RSACUM) for the cumulative PAYE method — cache path | 293 | RSACUM accumulators | `settings_auto_ytd` |
| 15 | **payslip_fact** | YTD **fallback** when `cumulative_ledger` is absent/empty (raw per-code facts) | 376 | `run_history_amounts` | `run_history_amounts`, `employee_run_amounts` |

Note tables 14–15 are **both inputs and outputs** — the run writes them, and a later
run reads them back as the cumulative (YTD) basis.

---

## OUTPUT tables — where results are persisted

The engine returns JSON; these are the tables the PHP persistence chain writes. Your
`employee_run*` / `run_history*` / `payslip_history*` equivalents:

| iteration-3 table (tenant) | Written by (file:line) | Legacy SQL Server / iteration-2 equivalent |
|---|---|---|
| **payroll_runs** | `pipro-payroll-za/.../ZaEngineRunController.php:119,177` | `run_history`, `pay_run_totals`, `pay_run_trace` |
| **payslips_core** (header/totals) | `ZaEngineRunPersister.php:76,84` · `ZwEngineRunPersister.php:64,72` | `payslips`, `payslip_history_general` |
| **payslip_core_earnings** | `ZaEngineRunPersister.php:104,108` (DELETE+INSERT) | `payslip_history_earnings` |
| **payslip_core_deductions** | `ZaEngineRunPersister.php:123,127` | `payslip_history_deductions` |
| **payslip_statutory_za** (PAYE/UIF/SDL) | `ZaEngineRunPersister.php:144,153` | `pay_run_tax_audit`, `payslip_history_statistics`, `settings_zaf_sars_*` |
| **payslip_statutory_zw** | `ZwEngineRunPersister.php:91,99` | (ZW analogue — no direct legacy table) |
| **payslip_fact** (per-code facts) | `PayslipFactWriter.php:59,74` via `Za/ZwPayslipFactProjector` | `employee_run_amounts`, `run_history_amounts` ← closest `employee_run*` match |
| **cumulative_ledger** (YTD) | `CumulativeLedgerRebuilder.php` (triggered by `PayslipFactWriter`) | `settings_auto_ytd`, YTD side of `run_history` |
| **employee_negative_balances** | `ZaRunStatutoryPostProcessor.php` | statutory carry-forward / negative-balance queue |
| **payroll_transactions** (write-back) | `ZaEngineRunController.php:145,264` | input file also updated post-run (`PW_Tranf` status) |

---

## Legacy name glossary (SQL Server → pipro)

Explicit ties found in the engine source:

| Legacy | Meaning | pipro | Cited at |
|---|---|---|---|
| `PW_IMF` | employee masterfile | employees + employee_contracts + assignments + recurring + status + medical | PostgresRunInputLoader.java:71 |
| `PW_Tranf_A` / `PW_Tranf` | period transaction file | payroll_transactions | PostgresRunInputLoader.java:71, 242 |
| `PW_Parm_Calculations` | per-payroll calc definition | calc_program (+ payrolls.tax_method) | PostgresRunInputLoader.java:493 |
| `settings_taxcodes` | code catalogue / tax-code IDs | payroll_code_catalogue (CodeId maps IDs) | CodeId.java:6 |
| `updateRunF` | legacy run header routine | EmployeeHeader (ported) | EmployeeHeader.java:7 |

---

## Boundary — NOT part of the engine run flow

Don't over-include these when mapping run outputs:

- **payroll_transactions** — primarily an *input* (period's entered lines); the run
  also writes back to it, but it is not a result table.
- **payslip_core_versions** — immutable snapshot written by `PayslipSnapshotter` at
  **approval**, not by the run.
- **payslip_core_adjustments** — **manual** user adjustments (period-keyed), not engine output.
- **payslip_core_previews** — a *preview* run mode (`PayrollRunController` writes/deletes
  by period), not a committed result.
- **irp5_certificates** — **year-end** SARS certificates (`SarsYearEndController`), annual.
- **payslip_fact via EmployeeImportController (hrm-core)** — the same fact table is also
  written during employee import (opening-balance / YTD take-on) — the migration on-ramp,
  not a run.
