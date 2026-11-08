# Differential testing — cragutils vs. FreeBSD vs. GNU

This harness implements PLAN.md P9: **FreeBSD behavior is the reference.**
cragutils comes from FreeBSD and we say so; when the port differs from
FreeBSD that is a bug unless it is declared in `DIFFERENCES/`.  Differing
from GNU while matching FreeBSD is expected — it is documented in
`TRADEOFFS`, never "fixed" toward GNU.

## Verdict classes (per case)

| Verdict | Meaning | Gate |
|---|---|---|
| `MATCH` | cragutils agrees with FreeBSD and GNU | pass |
| `DECLARED_DELTA` | cragutils-vs-FreeBSD mismatch that matches a `DIFFERENCES/` entry (the case's `delta:` hint names the entry) | pass |
| `DRIFT` | undeclared cragutils-vs-FreeBSD mismatch | **fail** |
| `GNU_DIVERGENCE` | cragutils matches FreeBSD (or FreeBSD is not being compared) but differs from GNU | pass (docs only) |
| `SKIP` | no comparable backend ran the case (tool missing, oracle absent) | pass |

DRIFT is the only gate-failing class.  When the FreeBSD backend is
absent, `GNU_DIVERGENCE` is provisional — the FreeBSD axis is what makes
a mismatch "expected" in the policy sense, and re-runs with the oracle
may reclassify.

## Layout

    tests/diff/
        run-diff.sh          the runner (POSIX sh)
        cases/<tool>.cases   one case table per tool (TSV)
        cases/<tool>.d/...   fixtures: @-referenced stdin files and
                             per-case working trees
        oracle/README.md     contract for the FreeBSD VM oracle

Reports: a human report on stdout (and `build/state/test-results/diff.txt`)
plus junit XML at `build/state/test-results/diff.xml`.  Exit status:
0 = no DRIFT, 1 = DRIFT found, 2 = setup error.

## Case table format

Five tab-separated fields per line in `cases/<tool>.cases`; `#` lines and
blank lines are ignored:

    id <TAB> argv <TAB> stdin <TAB> env <TAB> hints

* **id** — `[a-z0-9-]+`, unique within the table.
* **argv** — the full invocation *including the tool name as its first
  word* (harvest style, e.g. `stat -c %a f`).  The runner substitutes the
  backend's binary for that first word.  The field is parsed by the
  runner's shell, so POSIX quoting works (single quotes around awk/sed
  scripts).  No pipelines: one process per case.
* **stdin** — `-` (empty), `@path` (file relative to `cases/<tool>.d/`),
  or an inline literal where `printf %b` escapes (`\n`, `\t`, `\\`) are
  interpreted.
* **env** — `-` or space-separated `VAR=VAL` words added on top of the
  base environment (`LC_ALL=C TZ=UTC HOME=<run dir>`, plus the backend's
  PATH).
* **hints** — `-` or comma-separated explicit tokens.  Explicit only,
  never fuzzy matching:
  * `norm:workdir` — replace the run's working-directory path with
    `<WORKDIR>` in stdout before comparing.
  * `norm:toolpath` — replace the backend tool's absolute path with
    `<TOOL>`.
  * `norm:epoch` — replace maximal runs of exactly 10 digits with
    `<EPOCH>`.
  * `norm:sortlines` — sort output lines before comparing (for cases
    where ordering is a filesystem artifact, e.g. `find` traversal).
  * `post:<path>` — after the run, append `post:<path> size=N
    sha256=H` (or `MISSING`) for that file in the working dir to the
    compared output.  Use this to observe side effects (truncate sizes,
    sed -i results, patch application).
  * `delta:<text>` — declare that a cragutils-vs-FreeBSD mismatch on
    this case is explained by the `DIFFERENCES/` section whose heading
    contains `<text>` (case-insensitive; checked against the real
    headings, an invalid reference does not count as declared).

## Comparison semantics

Per case, cragutils is compared against each other backend:

* **stdout**: strict byte comparison after the case's normalization
  hints (plus the `post:` observations appended).
* **exit status**: strict.
* **stderr**: present/absent only — message wording legitimately differs
  between BSD and GNU.

The verdict ordering is DRIFT > DECLARED_DELTA > GNU_DIVERGENCE > MATCH.

## Determinism rules

* Every case runs in its own working dir (`<work>/runs/<backend>/<tool>/<id>/w`);
  harness artifacts (`out`, `err`, `obs`, `exit`) live one level up so
  they never appear in the tool's view of its directory — the oracle-side
  tree is exactly this working dir.
* `umask 022`; fixture mtimes are pinned to 2026-01-01 00:00 UTC (run
  artifacts, not tool behavior).
* `LC_ALL=C TZ=UTC`; argv must be deterministic — no wall-clock output,
  no randomness (that is why the harvested `jot -r` usage has no random
  cases).
* Cases must not have side effects outside their working dir.  In
  particular never use `date -s`/`date -f` without `-j` in a case:
  FreeBSD `date -f` *sets the clock* (it prints `clock_settime:
  Operation not permitted` unprivileged and would actually set the date
  as root).

## Backends

* `cragutils` — tools from a meson build tree (`--build`, default
  `build-meson`) or a flat `--bindir`.  PATH for `sh` cases is the tool
  dir first, then `/usr/bin:/bin`.
* `gnu` — `/usr/bin` (whatever the host calls its own tools; `sh` is
  whatever `/usr/bin/sh` is, dash on Ubuntu/Debian).
* `freebsd` — thin adapter around `tests/diff/oracle/run-on-freebsd.sh`
  (built separately; see `oracle/README.md` for the framed-output
  contract).  Skipped cleanly when the oracle is absent or reports exit
  77; an unparsable frame skips the case with a warning and can never
  produce a DRIFT verdict.

## Adding cases

Harvest real invocations first (Crag build scripts, hooks, dinit service
definitions), note the source in a `#` comment above the rows, then add
edge cases for the heavily-patched tools.  Aim for 5-15 high-value cases
per tool; every case must be deterministic and safe to run as any user.

    $ tests/diff/run-diff.sh --list
    $ tests/diff/run-diff.sh --tool stat          # iterate on one table
    $ tests/diff/run-diff.sh                      # full corpus
