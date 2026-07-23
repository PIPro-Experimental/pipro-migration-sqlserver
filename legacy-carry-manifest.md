# Legacy-carry manifest

Generated from DataDictionary.java. copyData=true tables: 111; in scope (COMPANY/PAYROLL): 109.

| table | schemaType | module | keys | auto-id | notes |
|---|---|---|---|---|---|
| settings_bank_transfer | COMPANY | core | transfer_no |  |  |
| settings_bank_transfer_value | COMPANY | core | transfer_no, record_type, ordinal_no |  |  |
| settings_currency | COMPANY | core | payroll |  |  |
| settings_user | COMPANY | core | payroll |  |  |
| settings_global | COMPANY | core | payroll |  |  |
| settings_user_tax | PAYROLL | core | payroll |  |  |
| settings_taxcodes | PAYROLL | core | payroll, currency |  |  |
| settings_payroll_dates | PAYROLL | core | ordinal_no |  | +payroll col |
| settings_payroll_precision_amounts | PAYROLL | core | ordinal_no |  | +payroll col |
| employee_increments | COMPANY | core | id | yes |  |
| run_history | PAYROLL | core | run_year, run_period, employee_id |  |  |
| run_history_amounts | PAYROLL | core | run_year, run_period, employee_id, ordinal_no, usage_id |  | +payroll col |
| run_history_alpha | PAYROLL | core | run_year, run_period, employee_id, ordinal_no |  | +payroll col |
| run_history_accounts | PAYROLL | core | run_year, run_period, employee_id, ordinal_no |  | +payroll col |
| settings_thirdparty_codes | COMPANY | core | ordinal_no |  |  |
| settings_thirdparty_dedtype | COMPANY | core | ded_type |  |  |
| settings_thirdparty_agents | COMPANY | core | agent_key |  |  |
| settings_thirdparty_eft | COMPANY | core | agent_key, ordinal_no |  |  |
| employee_thirdparty_transact | COMPANY | core | employee_id, trans_seq_no |  |  |
| settings_banks | COMPANY | core | branch_code |  |  |
| employee_interim | PAYROLL | core | employee_id |  | +payroll col |
| employee_interim_items | PAYROLL | core | employee_id, ordinal_no |  | +payroll col |
| employee_leave_history | COMPANY | core | id | yes |  |
| settings_auto_ytd | PAYROLL | core | ordinal_no |  | +payroll col |
| settings_calculations | PAYROLL | core | calc_set, ordinal_no |  | +payroll col |
| settings_calendar | PAYROLL | core | ordinal_no |  | +payroll col |
| settings_costcode_breaks | COMPANY | core | payroll, break_no, ordinal_no |  |  |
| settings_costing_codes | PAYROLL | core | ordinal_no |  | +payroll col |
| settings_costing_general | COMPANY | core | company_id |  |  |
| settings_company_third_party | COMPANY | core | company_id |  |  |
| settings_exceptions | PAYROLL | core | payroll, ordinal_no |  |  |
| settings_report | COMPANY | core | payroll, report_no |  |  |
| settings_report_breaks | COMPANY | core | payroll, report_no, break_set, ordinal_no |  |  |
| settings_report_calcs | COMPANY | core | payroll, report_no, ordinal_no |  |  |
| settings_report_details | COMPANY | core | payroll, report_no, ordinal_no |  |  |
| settings_report_headings | COMPANY | core | payroll, report_no, ordinal_no |  |  |
| settings_report_history | COMPANY | core | payroll, report_no, ordinal_no |  |  |
| settings_report_variables | COMPANY | core | payroll, template_no, link_ord_no, var_type |  |  |
| settings_report_totald | COMPANY | core | payroll, report_no, ordinal_no |  |  |
| settings_report_totals | COMPANY | core | payroll, report_no, ordinal_no |  |  |
| settings_report_storage | COMPANY | core | payroll, report_no, ordinal_no |  |  |
| settings_holidays | PAYROLL | core | ordinal_no |  | +payroll col |
| settings_leave_details | COMPANY | core | ordinal_no |  |  |
| settings_leave_history_report | COMPANY | core | report_no |  |  |
| settings_leave_history_report_breaks | COMPANY | core | report_no, ordinal_no |  |  |
| settings_leave_history_report_type | COMPANY | core | report_no, ordinal_no |  |  |
| settings_payslip | COMPANY | core | company_id |  |  |
| settings_payslip_amounts | COMPANY | core | ordinal_no |  |  |
| settings_payslip_descript | COMPANY | core | ordinal_no |  |  |
| settings_payslip_message | COMPANY | core | ordinal_no |  |  |
| settings_payslip_user | COMPANY | core | ordinal_no |  |  |
| settings_rolling_history | PAYROLL | core | ordinal_no |  | +payroll col |
| settings_rolling_hist_fields | PAYROLL | core | ordinal_no, date_table |  | +payroll col |
| settings_special_runs | PAYROLL | core | special_run_no |  | +payroll col |
| settings_split_payment_code | COMPANY | core | split_pay_code |  |  |
| settings_table_access | PAYROLL | core | ordinal_no |  | +payroll col |
| settings_table_values | PAYROLL | core | ordinal_no, row_no |  | +payroll col |
| pay_run_messages | PAYROLL | core | id | yes | +payroll col |
| pay_run_tax_audit | PAYROLL | core | id | yes | +payroll col |
| ratef | PAYROLL | core | id | yes | +payroll col |
| settings_taxcodes_cod_congo | PAYROLL | neighbour | payroll, currency |  |  |
| settings_taxcodes_gha_ghana | PAYROLL | neighbour | payroll, currency |  |  |
| settings_taxcodes_ken_kenya | PAYROLL | neighbour | payroll, currency |  |  |
| settings_user_mli_mali | PAYROLL | neighbour | payroll |  |  |
| settings_taxcodes_mus_mauritius | PAYROLL | neighbour | payroll, currency |  |  |
| settings_user_nam_namibia | PAYROLL | neighbour | payroll |  |  |
| settings_taxcodes_nam_namibia | PAYROLL | neighbour | payroll, currency |  |  |
| settings_taxcodes_swz_eswatini | PAYROLL | neighbour | payroll, currency |  |  |
| settings_tax_certificate_bwa_botswana | COMPANY | neighbour | payroll |  |  |
| settings_tax_certificate_bwa_blocks | COMPANY | neighbour | payroll, ordinal_no |  |  |
| settings_tax_certificate_bwa_calcs | COMPANY | neighbour | payroll, ordinal_no |  |  |
| settings_tax_certificate_lso_lesotho | COMPANY | neighbour | payroll |  |  |
| settings_tax_certificate_lso_calcs | COMPANY | neighbour | payroll, ordinal_no |  |  |
| settings_tax_certificate_swz_calcs | COMPANY | neighbour | payroll, ordinal_no |  |  |
| settings_tax_certificate_swz_header | COMPANY | neighbour | payroll, ordinal_no |  |  |
| settings_tax_certificate_swz_eswatini | COMPANY | neighbour | payroll |  |  |
| settings_user_zaf_southafrica | PAYROLL | za | payroll |  |  |
| equity | COMPANY | za | id | yes |  |
| employment_tax_incentive | COMPANY | za | eti_year, period_no, employee_id |  |  |
| fund_mibfa | COMPANY | za | company_id, employee_id |  |  |
| fund_mibfa_header | COMPANY | za | ordinal_no |  |  |
| fund_mibfa_other | COMPANY | za | company_id, employee_id, ordinal_no |  |  |
| settings_apso_tax | PAYROLL | za | payroll |  |  |
| settings_apso_tax_codes | COMPANY | za | payroll, ordinal_no |  |  |
| settings_equity | COMPANY | za | payroll |  |  |
| settings_zaf_uif_calcs | COMPANY | za | payroll, ordinal_no |  |  |
| settings_zaf_uif | COMPANY | za | payroll |  |  |
| settings_zaf_uif_company | COMPANY | za |  |  |  |
| settings_zaf_uif_file | COMPANY | za | file_no |  |  |
| settings_zaf_uif_file_sort | COMPANY | za | file_no, ordinal_no |  |  |
| settings_fund_coida | COMPANY | za | payroll |  |  |
| settings_zaf_sars_company_values | COMPANY | za | scvcc_value, scvsars_alpha |  |  |
| settings_zaf_sars_company | COMPANY | za | company_id |  |  |
| settings_zaf_sars_file | COMPANY | za | sars_parm_file_no |  |  |
| settings_zaf_sars_file_sort | COMPANY | za | sars_parm_file_no, ordinal_no |  |  |
| zaf_sars_print | COMPANY | za | page_no, line_number |  |  |
| zaf_sars_work | COMPANY | za | employee_id |  |  |
| settings_taxcodes_zwe_zimbabwe | PAYROLL | zw | payroll, currency |  |  |

## Skipped (already in pipro / handled separately)

- employees
- employee_amounts
- settings_employee_amounts
- employee_dates
- settings_employee_dates
- employee_precision_amounts
- settings_employee_precision_amounts
- employee_alpha
- settings_employee_alpha
- employee_thirdparty_payments
- employee_accounts

## Reserved-word renames

- settings_table_values.row -> row_no