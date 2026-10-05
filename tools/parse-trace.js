// Parse a Paywell UTL020 trace-print export (the "trace report" CSV offered
// alongside the PDF) into the client's CALC PROGRAM.
//
// To generate the csv file, execute a pay run with trace, then preview the report.
// In the preview, click the button to export the file. In the export window, change
// the dropdown to comma separated values and click ok. Tick both options to preserve 
// both date and amount formatting and click ok again.
//
// Usage: node parse-trace.js <trace.csv> [mode]
//
//   --listing              (default) the calc program, one line per distinct
//                          instruction, collapsed across every employee traced
//   --employee <n>         the full trace for one legacy EmpNo, in order
//   --ordinal <n>          every instruction touching that ordinal, any bank
//                          ("where does this value come from?")
//   --csv                  flat CSV of every instruction, for \copy into Postgres
//   --banks                operand-bank / opcode frequency summary
//
// WHY THIS EXISTS
// ---------------
// pw_* carries the VALUES a legacy payroll holds; it does not carry the RULES
// that produce them. Those live in the calc program, which has no readable
// source - the VB6 at repos/legacy-vb6 is six years stale and interprets the
// program rather than listing it. But a validation run can print a TRACE, and
// the trace is the program as executed: opcode, operands, banks, literals,
// jump targets, and the value each step produced.
//
// That is how the two gaps in the airplane comparison were specified:
//   bursary   calc 736        MOV C 0115 -> C 0116        (one instruction)
//   birthday  calc 683..695   month-of-birth test, then annual/365 * ytd-days
// Both reproduce legacy to the cent. Neither was recoverable from pw_* alone.
//
// LIMITS - read these before trusting a listing
//   * A TRACE IS NOT A LISTING. Only paths actually taken appear. A branch no
//     employee hit is invisible, and a rule that fires in February is invisible
//     in a July trace. On the airplane run, 675 distinct calc numbers executed
//     out of a range reaching 1446 - roughly half the program never ran.
//   * Values are per-employee. --listing prints ONE sample value as an
//     illustration of the step; it is not the rule.
//   * A conditional's jump target is captured, but the instructions it skips
//     are only visible through an employee who did not skip them.
//   * Field offsets are fixed because the export's page furniture is a fixed
//     width. They are VALIDATED on every row: anything not matching one of the
//     two known record shapes is counted and reported, never silently dropped.
const fs = require('fs');
const readline = require('readline');

const argv = process.argv.slice(2);
const file = argv[0];
if (!file || file.startsWith('--')) {
  console.error('Usage: node parse-trace.js <trace.csv> [--listing|--employee <n>|--ordinal <n>|--csv|--banks]');
  process.exit(1);
}
function opt(name) {
  const i = argv.indexOf(name);
  return i === -1 ? null : (argv[i + 1] || '');
}
const mode = argv.includes('--csv') ? 'csv'
  : argv.includes('--banks') ? 'banks'
  : argv.includes('--employee') ? 'employee'
  : argv.includes('--ordinal') ? 'ordinal'
  : 'listing';
const wantEmp = opt('--employee');
const wantOrd = opt('--ordinal') === null ? null : String(parseInt(opt('--ordinal'), 10));

// --- CSV ------------------------------------------------------------------
// RFC4180 fields, "" for a literal quote. The export never puts a newline
// inside a field (verified: line count equals record count), so one line is
// one record and the file can be streamed - it runs to ~90MB.
function splitCsv(line) {
  const out = [];
  let cur = '';
  let inStr = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (inStr) {
      if (c === '"') {
        if (line[i + 1] === '"') { cur += '"'; i++; } else { inStr = false; }
      } else { cur += c; }
      continue;
    }
    if (c === '"') { inStr = true; continue; }
    if (c === ',') { out.push(cur); cur = ''; continue; }
    if (c === '\r') { continue; }
    cur += c;
  }
  out.push(cur);
  return out;
}

// --- page furniture -------------------------------------------------------
// Every exported row repeats the entire page header before its record. The
// column headings end with the third 'Value', so the record starts after the
// LAST 'Value' in the prefix. Derived rather than hardcoded, so a differently
// configured export still parses; bounded so a payload 'Value' cannot move it.
function bodyStart(fields) {
  let at = -1;
  const limit = Math.min(fields.length, 64);
  for (let i = 0; i < limit; i++) {
    if (fields[i].trim() === 'Value') at = i;
  }
  return at === -1 ? -1 : at + 1;
}

// Offsets within the record. Two shapes share them:
//   instruction   calc ind . . OP . op1 val . . op2 val . when op3 val . l1 l2 l3
//   continuation  calc ind                           . (dest) val     .  .  . l3
//
// A CONTINUATION is the same instruction printed a second time, carrying only
// its result in a different bank: where the instruction stores to "S 225", the
// continuation reports "(C225)" with the identical value - the stored bank and
// the current-bank view of one write. They pair exactly (calc 183: 128 full,
// 128 continuations) and every continuation calc number also appears as a full
// instruction, so they add NO rule information and --listing drops them. They
// are kept in --csv, --employee and --ordinal, flagged '*', because seeing the
// current-bank value is useful when following a value through a run.
const F = {
  calc: 0, ind: 1, op: 4,
  o1: 6, v1: 7, o2: 10, v2: 11, when: 13, o3: 14, v3: 15,
  l1: 17, l2: 18, l3: 19,
};
const OPCODE = /^[A-Z]{2,4}[0-9]?$/;
const CODE = /^([A-Z]) (\d{4})$/;            // addressed operand, "C 0115"
const PAREN = /^\(([A-Z])(\d{1,4})\)$/;      // result-only destination, "(C225)"
const JUMP = /^\d{3,4}$/;                    // jump target in the op-3 slot

function operand(code, value, label) {
  const raw = (code || '').trim();
  const num = (value || '').trim();
  const o = {
    raw,
    bank: null,
    ordinal: null,
    jump: null,
    implicit: false,
    value: num === '' ? null : Number(num),
    label: (label || '').trim(),
  };
  let m;
  if ((m = raw.match(CODE))) {
    o.bank = m[1];
    o.ordinal = String(parseInt(m[2], 10));
  } else if ((m = raw.match(PAREN))) {
    o.bank = m[1];
    o.ordinal = String(parseInt(m[2], 10));
    o.implicit = true;
  } else if (JUMP.test(raw)) {
    o.jump = String(parseInt(raw, 10));
  }
  return o;
}

function show(o) {
  if (!o.raw) return '-';
  if (o.jump) return '-> ' + o.jump;
  const addr = o.bank + ' ' + String(o.ordinal).padStart(4, '0') + (o.implicit ? '*' : '');
  return o.label ? addr + ' ' + o.label : addr;
}

// --- accumulators ---------------------------------------------------------
const program = new Map();     // distinct instruction -> { rec, emps, sample }
const banks = new Map();
const opcodes = new Map();
const unparsed = [];
let employee = null;
let rows = 0;
let instrs = 0;
let continuations = 0;
let headers = 0;
let csvHeaderWritten = false;

function bump(map, k) {
  if (k) map.set(k, (map.get(k) || 0) + 1);
}

function emit(rec) {
  if (mode === 'banks') {
    bump(opcodes, rec.op || '(continuation)');
    for (const o of [rec.o1, rec.o2, rec.o3]) bump(banks, o.bank);
    return;
  }
  if (mode === 'employee') {
    if (rec.emp !== wantEmp) return;
    console.log(
      'calc ' + String(rec.calc).padStart(5) +
      ' ind ' + String(rec.ind).padStart(3) + '  ' +
      (rec.op || '(cont)').padEnd(7) + rec.when.padEnd(4) +
      ' | ' + show(rec.o1).padEnd(26) +
      ' | ' + show(rec.o2).padEnd(26) +
      ' | ' + show(rec.o3).padEnd(26) +
      ' | ' + [rec.v1, rec.v2, rec.v3].map(v => (v === null ? '-' : v)).join('  '));
    return;
  }
  if (mode === 'ordinal') {
    if (![rec.o1, rec.o2, rec.o3].some(o => o.ordinal === wantOrd)) return;
    console.log(
      'emp ' + String(rec.emp).padStart(4) +
      ' calc ' + String(rec.calc).padStart(5) + '  ' +
      (rec.op || '(cont)').padEnd(7) +
      ' | ' + show(rec.o1).padEnd(26) +
      ' | ' + show(rec.o2).padEnd(26) +
      ' | ' + show(rec.o3).padEnd(26) +
      ' | ' + [rec.v1, rec.v2, rec.v3].map(v => (v === null ? '-' : v)).join('  '));
    return;
  }
  if (mode === 'csv') {
    if (!csvHeaderWritten) {
      console.log('empno,calc_no,ind,op,store_when,' +
        'op1_bank,op1_ordinal,op1_label,op1_value,' +
        'op2_bank,op2_ordinal,op2_label,op2_value,' +
        'op3_bank,op3_ordinal,op3_label,op3_value,jump_to');
      csvHeaderWritten = true;
    }
    const q = (s) => {
      if (s === null || s === undefined) return '';
      const t = String(s);
      return /[",]/.test(t) ? '"' + t.replace(/"/g, '""') + '"' : t;
    };
    console.log([
      rec.emp, rec.calc, rec.ind, rec.op, rec.when,
      rec.o1.bank, rec.o1.ordinal, rec.o1.label, rec.v1,
      rec.o2.bank, rec.o2.ordinal, rec.o2.label, rec.v2,
      rec.o3.bank, rec.o3.ordinal, rec.o3.label, rec.v3, rec.o3.jump,
    ].map(q).join(','));
    return;
  }
  // listing: collapse the 187 per-employee traces back into one program.
  // Continuations are dropped - they restate a result the instruction above
  // already reported, so listing them would invent instructions that do not
  // exist and double-count the program.
  if (rec.cont) return;
  const key = [rec.calc, rec.ind, rec.op, rec.when,
    rec.o1.raw, rec.o2.raw, rec.o3.raw].join('|');
  let e = program.get(key);
  if (!e) {
    e = { rec, emps: new Set(), nonzero: 0, sample: null };
    program.set(key, e);
  }
  e.emps.add(rec.emp);
  if ([rec.v1, rec.v2, rec.v3].some(v => v !== null && v !== 0)) {
    e.nonzero++;
    if (!e.sample) {
      e.sample = { emp: rec.emp, v1: rec.v1, v2: rec.v2, v3: rec.v3 };
    }
  }
}

const rl = readline.createInterface({
  input: fs.createReadStream(file, { encoding: 'utf8' }),
  crlfDelay: Infinity,
});

rl.on('line', (line) => {
  if (!line.trim()) return;
  rows++;
  const fields = splitCsv(line);
  const start = bodyStart(fields);
  if (start === -1) { unparsed.push([rows, 'no page header found']); return; }
  let b = fields.slice(start);

  if (b.length && b[0].trim().startsWith('Employee No.')) {
    const m = b[0].trim().match(/^Employee No\.\s+(\d+)/);
    if (m) { employee = m[1]; headers++; }
    b = b.slice(1);
  }

  const g = (i) => (b.length > i ? b[i].trim() : '');
  const calc = g(F.calc);
  const ind = g(F.ind);
  const op = g(F.op);
  const numbered = /^\d+$/.test(calc) && /^\d+$/.test(ind);
  const isInstr = numbered && OPCODE.test(op);
  const isCont = numbered && !op && g(F.o3) !== '';
  if (!isInstr && !isCont) { unparsed.push([rows, b.slice(0, 20).join('|')]); return; }
  if (isInstr) { instrs++; } else { continuations++; }

  const o1 = operand(g(F.o1), g(F.v1), g(F.l1));
  const o2 = operand(g(F.o2), g(F.v2), g(F.l2));
  const o3 = operand(g(F.o3), g(F.v3), g(F.l3));
  emit({
    emp: employee, calc: Number(calc), ind: Number(ind), op, when: g(F.when),
    o1, o2, o3, v1: o1.value, v2: o2.value, v3: o3.value, cont: isCont,
  });
});

rl.on('close', () => {
  if (mode === 'banks') {
    const dump = (title, m) => {
      console.log('\n' + title);
      [...m.entries()].sort((a, b) => b[1] - a[1])
        .forEach(([k, v]) => console.log('  ' + String(k).padEnd(8) + v));
    };
    dump('operand banks:', banks);
    dump('opcodes:', opcodes);
  }
  if (mode === 'listing') {
    const all = [...program.values()]
      .sort((a, b) => a.rec.calc - b.rec.calc || a.rec.ind - b.rec.ind);
    console.log(
      'calc   ind  op      when | op-1                       | op-2                       | dest/jump                  | emps  sample');
    console.log('-'.repeat(172));
    for (const e of all) {
      const r = e.rec;
      const s = e.sample
        ? 'emp ' + e.sample.emp + ': ' +
          [e.sample.v1, e.sample.v2, e.sample.v3].map(v => (v === null ? '-' : v)).join('  ')
        : '(all zero)';
      console.log(
        String(r.calc).padStart(5) + ' ' + String(r.ind).padStart(4) + '  ' +
        (r.op || '(cont)').padEnd(7) + ' ' + r.when.padEnd(4) +
        ' | ' + show(r.o1).padEnd(26) +
        ' | ' + show(r.o2).padEnd(26) +
        ' | ' + show(r.o3).padEnd(26) +
        ' | ' + String(e.emps.size).padStart(4) + '  ' + s);
    }
  }
  const summary = [
    '',
    '-'.repeat(60),
    'rows ' + rows + '  instructions ' + instrs +
      '  continuations ' + continuations + '  employee headers ' + headers,
    mode === 'listing'
      ? 'distinct instructions ' + program.size + ' (continuations excluded)'
      : '',
    'unparsed ' + unparsed.length,
  ].filter(Boolean).join('\n');
  console.error(summary);
  for (const [n, why] of unparsed.slice(0, 10)) console.error('  row ' + n + ': ' + why);
  if (unparsed.length) {
    console.error('  ^ report these: the export shape has changed, so the output is INCOMPLETE.');
  }
});
