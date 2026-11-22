'use strict';
// suites.js -- an Nx plugin that makes each test suite in tests/ one Nx project with one cached
// target. Every run of the suites goes through it: the commit hook and publish-check (cached), the
// apply (cached before, uncached after) and the landing gate (uncached, with the mutant tests), all
// by way of tests/apply-suites.py. A suite whose inputs did not change since it last passed replays
// from Nx's cache; every suite whose inputs changed runs.
//
// THE MAP IS THE ONLY SOURCE OF TRUTH. tests/coverage.map says what each suite reads; this file
// turns each line into the target's inputs, so a path a suite reads is a path whose edit re-runs it.
//
// A MALFORMED MAP THROWS. A partial graph would read as "this suite reads less than it does",
// which replays a stale green from the cache. A hard failure of every Nx command is the cheaper
// error, so a line naming no suite, a line with no globs, a glob matching no tracked file, a suite
// with no line and a glob Nx would read differently all throw here.
//
// THE MAP MUST ALSO COVER THE TREE, and that is checked by `node tools/nx/suites.js --check`
// (COVERAGE below), run by tests/test-coverage-map.py, rather than thrown: a tracked file that no
// suite claims re-runs nothing when it changes, so it is refused until a line claims or exempts it,
// and so is a suite that names a tracked path it does not claim.
//
// The map's glob dialect: `*` any run but `/`, `**` any run including `/`, `?` one character but
// `/`; every other character is literal. The coverage check reads globs as regexes in that
// dialect; Nx hashes file inputs with a Rust glob matcher whose dialect differs, so GLOB
// TRANSLATION below is the one place the two meet, and tests/test-nx-suites.sh holds them together.
//
// SERIAL SUITES. A suite marked `# run-all: serial` (the exact line among its first 10; the name is
// the retired shell runner's, kept so no suite had to change) asserts on CPU or wall time and fails
// under load with no defect. The plugin gives that target `parallelism: false`, which Nx's scheduler
// (tasks-schedule.js canBeScheduled, Nx 24.0.2) starts only when nothing else runs and lets nothing
// start beside. This is not a throttle on machine load: such a suite's verdict measures CPU or wall
// time, so the CPU is the resource it needs to itself, as another target needs a fixed port. Task
// concurrency stays at Nx's default (no `parallel` in nx.json); a machine that wants more sets
// NX_PARALLEL.
//
// MAP_ENV exists for tests/test-nx-suites.sh and tests/test-coverage-map.py alone: it points the
// plugin at a scratch map so a broken map can be tried without touching the real one.

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const MAP_ENV = 'NX_SUITES_MAP_FOR_TESTS';
const MAP_FILE = 'tests/coverage.map';

// mise moves with the package manager rather than a pin, so a cached pass must not replay once it
// changes. The input is a checksum of the mise binary on PATH, not `mise --version`: that command
// checks for a newer release over the network and reports the result on stderr, which Nx hashes
// with stdout, so two runs of the same mise gave two hashes (measured with mise 2026.11.5 and
// Nx 24.0.5, the network refused). cksum is POSIX, so the line is the same on Linux and macOS; it
// read the 160 MB Linux binary in under 0.1 s. A machine without mise hashes a fixed line.
// tests/test-nx-suites.sh holds this input steady across two runs and changed by a stand-in mise.
const MISE_INPUT = 'm=$(command -v mise) && cksum < "$m" || echo "mise: not installed"';

// What the suites run through, by runtime and not by file: a different OS or tool version can
// change a suite's result with no file edit, so a cache entry must not outlive it.
const RUNTIME_INPUTS = [
  'uname -s',
  'git --version',
  'zsh --version',
  'uv --version',
  'python3 --version',
  'chezmoi --version',
  MISE_INPUT,
];

// THE SET OF TRACKED FILES. A whole-tree check (a `tree` line), and a suite named below, judges the
// files git tracks, so its verdict can change when a file is added, deleted or staged while no
// claimed file's content changes. Those targets also hash the index's file list. Under the commit
// hook that is what is staged, which is what such a check reads.
const TRACKED_LIST = 'git ls-files';
const READS_TRACKED_LIST = {
  'test-nx-suites.sh': 'the plugin refuses a glob matching no tracked file, and the suite copies every tracked file',
  'test-npm-registry.py': 'refuses a tracked .npmrc anywhere',
};

// What else a suite's verdict depends on that no file glob can name, by suite. The plugin reads
// the first 10 lines of every suite (its interpreter and the serial marker), so the suite that
// tests the plugin hashes exactly those lines rather than every suite's whole text, which would
// re-run it on every suite edit.
const EXTRA_RUNTIME = {
  'test-nx-suites.sh': ['for f in tests/test-*; do echo "$f"; head -n 10 "$f"; done'],
};

// THE CONTEXT A SUITE RAN IN. A suite can pass inside a Claude Code session's sandbox and fail in a
// terminal: one did, because the sandbox could not write /tmp, so the leak it checks for could not
// happen there. Claude Code sets SANDBOX_RUNTIME in a sandboxed command, so hashing the variable
// keeps a pass recorded in a sandbox from replaying in a terminal, and the reverse. RUN_MUTANTS
// selects the slow mutant tests a suite ships (the landing gate sets it), so a pass without them
// never replays for a run that asked for them. Every suite's target carries both, since which suites
// they change cannot be known in advance.
const ENV_INPUTS = ['SANDBOX_RUNTIME', 'RUN_MUTANTS'];

// HOW ONE SUITE RUNS. The interpreter comes from the suite's shebang: a zsh suite run through `sh`
// fails on zsh-only syntax, which reads like a broken test rather than a broken runner, and a PEP
// 723 suite (`#!/usr/bin/env -S uv run --script`) runs as `uv run --script`. A machine without the
// interpreter fails the target (exit 127), never a silent pass. The suite's stdin is /dev/null.
// The environment, for every suite:
//   * git ignores the machine's global and system config (tests/git-isolated.gitconfig), so no
//     suite can fire the machine's commit hooks or sign; TEST_GIT_ISOLATED tells
//     tests/git-isolate.sh it is already done. The path is built from the task's working directory
//     (the workspace root) in the command, never written into the graph, so every checkout of the
//     repository computes the same task hash and shares one cache;
//   * Python writes no bytecode and pytest no cache directory: written inside the checkout they are
//     files one suite leaves for the next to read, which a cache hit cannot restore and Nx cannot hash.
//     PYTHONPYCACHEPREFIX, set in the command to a directory under $TMPDIR that nothing writes, moves
//     the bytecode Python and pytest's assertion rewriting would READ out of the checkout too: a
//     stale tests/__pycache__ left by a run by hand was read by a suite (verify-task-io, at landing);
//   * no color. Nx sets FORCE_COLOR=true for every task, so a child pytest colored its summary and a
//     suite matching `\b1 failed\b` in it found an escape code where the word boundary was: every
//     mutant meta-test failed under Nx while passing outside it (measured with Nx 24.0.5). A suite
//     reads its tools' output as plain text, as it did when no runner forced color;
//   * never the machine's timing slot. A commit hook the suites install in a scratch repository
//     calls `fleet-slot check` and, while another session holds the slot, waits up to 45 minutes
//     for it, so a slot held during an apply stalled the after-apply run by that long. The state
//     directory named here does not exist and cannot be created without root: a check reads it as
//     a free slot, and a suite that writes the slot without setting its own fails loudly instead
//     of leaving a held slot for the next suite to wait on. A suite that tests the slot sets
//     FLEET_SLOT_STATE itself.
const SUITE_ENV = {
  GIT_CONFIG_NOSYSTEM: '1',
  TEST_GIT_ISOLATED: '1',
  PYTHONDONTWRITEBYTECODE: '1',
  PYTEST_ADDOPTS: '-p no:cacheprovider',
  FORCE_COLOR: '0',
  NO_COLOR: '1',
  PY_COLORS: '0',
  FLEET_SLOT_STATE: '/nonexistent/fleet-slot-for-suites',
};
const SHELLS = ['sh', 'bash', 'zsh'];

function suiteCommand(suite, head) {
  const bang = head[0] || '';
  let interp;
  if (bang.startsWith('#!') && bang.includes('uv run --script')) interp = 'uv run --script';
  else {
    const m = bang.startsWith('#!') ? bang.trimEnd().match(/[/ ]([^/ ]+)$/) : null;
    interp = m ? m[1] : '';
    if (!SHELLS.includes(interp)) {
      fail('tests/' + suite + ': its first line names no interpreter this plugin runs (sh, bash, zsh, or `uv run --script`): ' + (bang || '(empty)'));
    }
  }
  return 'GIT_CONFIG_GLOBAL="$PWD/tests/git-isolated.gitconfig" PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/suites-no-pycache" exec ' + interp + ' tests/' + suite + ' < /dev/null';
}

// The map's globs as regexes in the map's own dialect. Kept as a regex, not a Nx glob, for the jobs
// a Nx glob cannot do here: telling whether a glob matches any tracked file (a dead line), and the
// coverage check.
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

// Parse the map: `#` starts a comment anywhere on a line, fields split on blanks and tabs, a
// leading keyword (or else a suite file name) picks the line form.
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
    for (const glob of f.slice(first)) entries.push({ kind, owner, glob, where, re: globToRegExp(glob) });
  });
  return { entries, hasLine };
}

// A suite whose verdict depends on something no input can name at all runs every time, with its
// reason here.
const UNCACHED = {
  'test-mise-installed.py': "checks this machine's mise, its mise configuration and files under $HOME, which no input names",
};

const SERIAL_MARK = '# run-all: serial';
function suiteHead(root, suite) {
  return fs.readFileSync(path.join(root, 'tests', suite), 'utf8').split('\n').slice(0, 10);
}

function listSuites(root) {
  return fs
    .readdirSync(path.join(root, 'tests'), { withFileTypes: true })
    .filter((e) => e.isFile() && /^test-.*\.(sh|py)$/.test(e.name))
    .map((e) => e.name)
    .sort();
}

// Tracked files, as git's index lists them, so under the commit hook the map is judged against
// what is staged.
function trackedFiles(root) {
  const out = execFileSync('git', ['ls-files', '-z'], { cwd: root, encoding: 'utf8', maxBuffer: 1 << 28 });
  return out.split('\0').filter((p) => p !== '');
}

// The map, read and held to the rules that throw. Returns what both the graph and the coverage
// check need.
function readMap(root) {
  const mapPath = process.env[MAP_ENV] || path.join(root, MAP_FILE);
  const suites = listSuites(root);
  const { entries, hasLine } = parseMap(mapPath, suites);
  const tracked = trackedFiles(root);
  for (const e of entries) {
    // Translate first: a glob Nx would read differently is refused whether or not it matches a file.
    if (e.kind === 'suite' || e.kind === 'tree' || e.kind === 'core') toNxGlob(e.glob);
    if (!tracked.some((p) => e.re.test(p))) fail(e.where + ': ' + e.kind + ' glob ' + e.glob + ' matches no tracked file');
  }
  for (const s of suites) if (!hasLine.has(s)) fail(s + ' has no line in the map: every suite declares what it reads');
  return { mapPath, suites, entries, tracked };
}

function projectName(suite) {
  return 'suite-' + suite.replace(/^test-/, '').replace(/\.(sh|py)$/, '');
}

function buildProjects(root) {
  const { suites, entries } = readMap(root);
  const core = entries.filter((e) => e.kind === 'core').map((e) => e.glob);
  const projects = {};
  // TWO SUITE FILES, ONE NAME: `test-x.sh` and `test-x.py` both become `suite-x`, and the second
  // silently replaced the first, so one suite was neither run nor cached. A port passes through
  // exactly that state (the new suite lands beside the old), so it is refused here, naming both.
  const named = {};
  for (const s of suites) {
    const name = projectName(s);
    if (named[name]) fail(named[name] + ' and ' + s + ' both name the project ' + name + ': rename one, or delete the one a port replaces');
    named[name] = s;
  }
  for (const s of suites) {
    const head = suiteHead(root, s);
    const mine = entries.filter((e) => (e.kind === 'suite' || e.kind === 'tree') && e.owner === s);
    // A suite file claims itself; a `tree` line is a whole-tree check, whose globs are inputs too.
    const globs = Array.from(new Set(['tests/' + s].concat(mine.map((e) => e.glob)).concat(core)));
    const runtime = RUNTIME_INPUTS.slice();
    if (mine.some((e) => e.kind === 'tree') || s in READS_TRACKED_LIST) runtime.push(TRACKED_LIST);
    runtime.push(...(EXTRA_RUNTIME[s] || []));
    projects['tests/suites/' + projectName(s)] = {
      name: projectName(s),
      targets: {
        test: {
          executor: 'nx:run-commands',
          options: { command: suiteCommand(s, head), env: SUITE_ENV },
          cache: !(s in UNCACHED),
          ...(head.includes(SERIAL_MARK) ? { parallelism: false } : {}),
          inputs: globs
            .map((g) => '{workspaceRoot}/' + toNxGlob(g))
            .concat(runtime.map((r) => ({ runtime: r })))
            .concat(ENV_INPUTS.map((v) => ({ env: v }))),
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

// COVERAGE: does the map cover the tracked tree? Two findings, each a way a change could re-run
// nothing that reads it:
//   * unclaimed: a tracked file that no suite claims, the core does not hold and no exemption names
//     (a suite file claims itself; a `tree` or `refs` line claims nothing);
//   * unclaimed read: a suite whose text names a tracked path outside tests/ (`dir/file`, or a tool
//     as `executable_<name>`) that its own lines and the core do not cover. A name that is only
//     fixture text is declared with `refs`.
// A name counts only whole: not inside a longer path or word.
function namesWhole(text, word) {
  let from = 0;
  for (;;) {
    const at = text.indexOf(word, from);
    if (at < 0) return false;
    const before = at > 0 ? text[at - 1] : '';
    const after = text[at + word.length] || '';
    if (!/[A-Za-z0-9_.-]/.test(before) && !/[A-Za-z0-9_.-]/.test(after)) return true;
    from = at + 1;
  }
}

function coverageFindings(root) {
  const { suites, entries, tracked } = readMap(root);
  const findings = [];
  const claims = entries.filter((e) => e.kind === 'core' || e.kind === 'suite' || e.kind === 'exempt');
  for (const p of tracked) {
    if (/^tests\/test-[^/]*$/.test(p)) continue;
    if (!claims.some((e) => e.re.test(p))) findings.push('unclaimed: ' + p + ' -- no suite claims it and no exemption names it');
  }
  const named = tracked.filter((p) => p.includes('/') && !p.startsWith('tests/'));
  for (const s of suites) {
    const text = fs.readFileSync(path.join(root, 'tests', s), 'utf8');
    const covers = entries.filter((e) => e.kind === 'core' || (e.owner === s && e.kind !== 'exempt'));
    for (const p of named) {
      const tool = p.startsWith('private_dot_local/bin/executable_') ? p.slice(p.lastIndexOf('/') + 1) : null;
      if (!namesWhole(text, p) && !(tool && namesWhole(text, tool))) continue;
      if (!covers.some((e) => e.re.test(p))) {
        findings.push('unclaimed read: ' + s + ' names ' + p + ' but does not claim it (claim it, or `refs` if it is fixture text)');
      }
    }
  }
  return { findings, tracked: tracked.length };
}

const createNodes = [
  MAP_FILE,
  (_files, _options, context) => [[MAP_FILE, { projects: buildProjects(context.workspaceRoot) }]],
];

module.exports = { createNodes, createNodesV2: createNodes, globToRegExp, readMap, buildProjects, coverageFindings, projectName, MISE_INPUT };

// `node tools/nx/suites.js --check [<workspace root>]`: the coverage check, run by
// tests/test-coverage-map.py. Exit 0 the map covers the tree; 1 a finding (each printed); 2 the map
// itself is refused (the error the plugin would throw).
if (require.main === module) {
  const args = process.argv.slice(2);
  if (args[0] !== '--check' || args.length > 2) {
    process.stderr.write('usage: node tools/nx/suites.js --check [<workspace root>]\n');
    process.exit(2);
  }
  const root = path.resolve(args[1] || path.join(__dirname, '..', '..'));
  let result;
  try {
    result = coverageFindings(root);
  } catch (e) {
    process.stderr.write(e.message + '\n');
    process.exit(2);
  }
  for (const f of result.findings) process.stdout.write('  ' + f + '\n');
  if (result.findings.length) {
    process.stdout.write('suites --check: ' + result.findings.length + ' finding(s) in ' + MAP_FILE + '\n');
    process.exit(1);
  }
  process.stdout.write('suites --check: the map covers all ' + result.tracked + ' tracked files\n');
}
