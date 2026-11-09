'use strict';
// suites.js -- an Nx plugin that makes each test suite in tests/ one Nx project with one cached
// target, so a landing gate can replay a suite whose inputs did not change.
//
// THE MAP IS THE ONLY SOURCE OF TRUTH. tests/coverage.map says what each suite reads, and
// tests/select-suites.sh already turns it into the commit-time selection. This file parses the
// SAME lines with the SAME glob semantics, so the commit tier and the cache can never disagree
// about a suite's reach: a path that selects a suite at commit is an input that invalidates its
// cache entry, and the reverse. tests/test-nx-suites.sh holds the two against each other.
//
// A MALFORMED MAP THROWS. A partial graph would read as "this suite reads less than it does",
// which replays a stale green from the cache. A hard failure of every Nx command is the cheaper
// error, so each finding select-suites.sh --check refuses (and its exit 2 parse errors) throws here.
//
// The map's glob dialect: `*` any run but `/`, `**` any run including `/`, `?` one character but
// `/`; every other character is literal. The selector does that with an awk regex; Nx hashes
// file inputs with a Rust glob matcher whose dialect differs, so GLOB TRANSLATION below is the
// one place the two meet.
//
// SERIAL SUITES. tests/run-all.sh runs a suite marked `# run-all: serial` alone, after the others,
// because it asserts on CPU or wall time and fails under load with no defect. The plugin reads the
// marker the way the runner does (the exact line among the first 10) and gives that target
// `parallelism: false`, which Nx's scheduler (tasks-schedule.js canBeScheduled, Nx 24.0.2) starts
// only when nothing else runs and lets nothing start beside: the same "alone". This is not a
// throttle on machine load: such a suite's verdict measures CPU or wall time, so the CPU is the
// resource it needs to itself, as another target needs a fixed port. Task concurrency stays at
// Nx's default (no `parallel` in nx.json); a machine that wants more sets NX_PARALLEL.
//
// MAP_ENV exists for tests/test-nx-suites.sh alone: it points the plugin at a scratch map so a
// broken map can be tried without touching the real one.

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const MAP_ENV = 'NX_SUITES_MAP_FOR_TESTS';
const MAP_FILE = 'tests/coverage.map';

// What the suites run through, by runtime and not by file: a different OS or tool version can
// change a suite's result with no file edit, so a cache entry must not outlive it.
const RUNTIME_INPUTS = [
  'uname -s',
  'git --version',
  'zsh --version',
  'uv --version',
  'python3 --version',
  'chezmoi --version',
];

// The map's globs, as the selector's regex builder reads them (select-suites.sh glob2re). Kept
// as a regex, not a Nx glob, for the one job a Nx glob cannot do here: telling whether a glob
// matches any tracked file, which is how a dead line is found.
function globToRegExp(glob) {
  let out = '^';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        out += '.*';
        i++;
      } else out += '[^/]*';
    } else if (c === '?') out += '[^/]';
    else if ('.+(){}$|'.includes(c)) out += '[' + c + ']';
    else if ('^[]\\'.includes(c)) out += '\\' + c;
    else out += c;
  }
  return new RegExp(out + '$');
}

// GLOB TRANSLATION. Measured against Nx 24.0.2's resolved file inputs (`nx show target inputs
// --check`, on a scratch workspace holding dot files, nested directories and names with braces):
//   * `*` and `?` never cross `/` and do match a leading dot, exactly as the map's do;
//   * `**` as the whole glob, or as the last path component (`dir/**`), crosses `/`, as the map's does;
//   * `**` anywhere else is NOT the map's `**`: Nx lets `a/**/y.sh` match `a/y.sh` (zero directories),
//     which the map's `a/.*/y.sh` does not, and treats `foo**` as a plain `*`;
//   * `{`, `[`, `\` and a leading `!` are glob syntax in Nx and literal in the map (a file named
//     `br{ace}.sh` matched nothing).
// So a glob in the map's shared subset passes through unchanged, and every other glob THROWS: a
// translation that silently changes what a glob reaches is the partial graph this file refuses.
// The map has no glob outside the subset today; one that needs it extends this function and the
// differential in tests/test-nx-suites.sh together.
function toNxGlob(glob) {
  if (!/^[A-Za-z0-9_.\-/*?]+$/.test(glob)) fail('glob ' + glob + ' has a character outside the subset Nx reads as the map does');
  if (glob.includes('**') && !(glob === '**' || (glob.endsWith('/**') && !glob.slice(0, -3).includes('**')))) {
    fail('glob ' + glob + ' uses ** other than as the whole glob or its last component, where Nx reads it differently');
  }
  return glob;
}

function fail(msg) {
  throw new Error('suites plugin: ' + msg);
}

// Parse the map the way the selector's awk does: `#` starts a comment anywhere on a line, fields
// split on blanks and tabs, a leading keyword (or else a suite file name) picks the line form.
function parseMap(mapPath, suites) {
  const known = new Set(suites);
  const entries = [];
  const hasLine = new Set();
  const lines = fs.readFileSync(mapPath, 'utf8').split('\n');
  lines.forEach((raw, idx) => {
    const where = mapPath + ':' + (idx + 1);
    const f = raw.replace(/#.*/, '').split(/[ \t]+/).filter((w) => w !== '');
    if (f.length === 0) return;
    let kind = f[0];
    let owner = '';
    let first = 1;
    if (kind === 'tree' || kind === 'refs') {
      owner = f[1] || '';
      first = 2;
    } else if (kind !== 'core' && kind !== 'exempt') {
      owner = f[0];
      kind = 'suite';
    }
    if (owner !== '' && !known.has(owner)) fail(where + ': names no suite in tests/: ' + owner);
    if (f.length < first + 1) fail(where + ': a line with no globs');
    if (owner !== '') hasLine.add(owner);
    for (const glob of f.slice(first)) entries.push({ kind, owner, glob, where });
  });
  return { entries, hasLine };
}

const SERIAL_MARK = '# run-all: serial';
function isSerial(root, suite) {
  const lines = fs.readFileSync(path.join(root, 'tests', suite), 'utf8').split('\n').slice(0, 10);
  return lines.includes(SERIAL_MARK);
}

function listSuites(root) {
  return fs
    .readdirSync(path.join(root, 'tests'), { withFileTypes: true })
    .filter((e) => e.isFile() && /^test-.*\.(sh|py)$/.test(e.name))
    .map((e) => e.name)
    .sort();
}

// Tracked files, as the selector's --check reads them (the index), so both judge the same tree.
function trackedFiles(root) {
  const out = execFileSync('git', ['ls-files', '-z'], { cwd: root, encoding: 'utf8', maxBuffer: 1 << 28 });
  return out.split('\0').filter((p) => p !== '');
}

function buildProjects(root) {
  const mapPath = process.env[MAP_ENV] || path.join(root, MAP_FILE);
  const suites = listSuites(root);
  const { entries, hasLine } = parseMap(mapPath, suites);
  const tracked = trackedFiles(root);
  for (const e of entries) {
    // Translate first: a glob Nx would read differently is refused whether or not it matches a file.
    if (e.kind === 'suite' || e.kind === 'tree' || e.kind === 'core') toNxGlob(e.glob);
    const re = globToRegExp(e.glob);
    if (!tracked.some((p) => re.test(p))) fail(e.where + ': ' + e.kind + ' glob ' + e.glob + ' matches no tracked file');
  }
  for (const s of suites) if (!hasLine.has(s)) fail(s + ' has no line in the map: every suite declares what it reads');

  const core = entries.filter((e) => e.kind === 'core').map((e) => e.glob);
  const projects = {};
  for (const s of suites) {
    const name = 'suite-' + s.replace(/^test-/, '').replace(/\.(sh|py)$/, '');
    // A suite file claims itself; a `tree` line is a whole-tree check, whose globs are inputs too.
    const globs = ['tests/' + s]
      .concat(entries.filter((e) => (e.kind === 'suite' || e.kind === 'tree') && e.owner === s).map((e) => e.glob))
      .concat(core);
    const unique = Array.from(new Set(globs));
    projects['tests/suites/' + name] = {
      name,
      targets: {
        test: {
          executor: 'nx:run-commands',
          options: { command: 'sh tests/run-all.sh --only ' + s },
          cache: true,
          ...(isSerial(root, s) ? { parallelism: false } : {}),
          inputs: unique.map((g) => '{workspaceRoot}/' + toNxGlob(g)).concat(RUNTIME_INPUTS.map((r) => ({ runtime: r }))),
          outputs: [],
        },
      },
    };
  }
  // The control a tracer needs: one target that does nothing, so a run of it shows Nx's own file
  // reads and writes, which a trace of each suite then subtracts (verify-task-io). Not cached, so
  // it is never audited as a suite would be.
  projects['tools/nx/control'] = {
    name: 'control',
    targets: { noop: { executor: 'nx:noop', cache: false } },
  };
  return projects;
}

const createNodes = [
  MAP_FILE,
  (_files, _options, context) => [[MAP_FILE, { projects: buildProjects(context.workspaceRoot) }]],
];

module.exports = { createNodes, createNodesV2: createNodes, globToRegExp };
