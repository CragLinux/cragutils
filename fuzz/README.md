# Fuzzing cragutils parsers

libFuzzer harnesses for code paths that consume untrusted input.

## Targets

- `fuzz_unvis` — `strunvis`/`unvis` (src.freebsd/compat/unvis.c): decodes
  vis(3)-encoded strings.
- `fuzz_getdate` — `getdate()` (src.freebsd/findutils/find/getdate.y): yacc
  date parser, reachable via `find -newermt` and others.
- `fuzz_setmode` — `setmode`/`getmode` (src.freebsd/compat/setmode.c):
  symbolic mode parser, reachable via `chmod`/`mkdir -m`/`install -m`.
- `fuzz_patch` — patch(1)'s diff parser: `open_patch_file` +
  `there_is_another_patch` + `another_hunk` over attacker input. Ed scripts
  are never executed (`ED_DIFF` breaks out before `do_ed_script`).
- `fuzz_http` — libfetch reply/header/chunked parsers plus the pure
  string parsers (`http_parse_length`, `http_parse_range`,
  `http_parse_mtime`, `http_parse_authenticate`, header lexer).
- `fuzz_telnet` — telnet(1) `telrcv` IAC negotiation + suboption parsers.
- `fuzz_sh` — dash `parsecmd` (shell parser).
- `fuzz_zopen` — LZW `.Z` decode/roundtrip (compress.c).
- `fuzz_awkb` — awk program parser + regex engine (b.c).
- `fuzz_grepdata` — grep(1) stdin data path.
- `fuzz_sedcompile` — sed(1) script compiler + interpreter over a fixed
  5-line input.  Input byte 0 is a flags byte (bit 0 = `-E`, bit 1 =
  `-n`); the rest is the script.  Scripts that can loop (resolved
  `b`/`t`, `D`) are compiled but not interpreted.
- `fuzz_seddata` — sed(1) interpreter with a fixed script over fuzzed
  input data.
- `fuzz_awkdata` — awk interpreter data path (CSV / regex RS/FS flavors).
- `fuzz_patch_struct` — grammar-mutated diffs (byte-level mutation from
  minimal seeds reaches shallower parse states).

## Building

Requires the system clang (libFuzzer) and a configured meson tree:

```sh
meson setup build-meson && ninja -C build-meson   # once, for config-compat.h/getdate.c/libcompat.a
sh fuzz/build-fuzz.sh
```

## Running

```sh
ASAN_OPTIONS=detect_leaks=0 fuzz/bin/fuzz_unvis   fuzz/corpus/unvis   -max_total_time=300 -artifact_prefix=fuzz/artifacts/
ASAN_OPTIONS=detect_leaks=0 fuzz/bin/fuzz_getdate fuzz/corpus/getdate -max_total_time=300 -artifact_prefix=fuzz/artifacts/
ASAN_OPTIONS=detect_leaks=0 fuzz/bin/fuzz_setmode fuzz/corpus/setmode -max_total_time=300 -artifact_prefix=fuzz/artifacts/
ASAN_OPTIONS=detect_leaks=0 fuzz/bin/fuzz_patch   fuzz/corpus/patch   -max_total_time=300 -rss_limit_mb=4096 -artifact_prefix=fuzz/artifacts/
```

Note: `fuzz_patch` deliberately leaks hunk-line storage of fatal-rejected
inputs (freeing them is unsafe — see SECURITY-FINDINGS.md), so long runs
need a raised `-rss_limit_mb` or periodic restarts.

Crashes land in `fuzz/artifacts/`. Minimize with
`fuzz/bin/fuzz_<t> fuzz/artifacts/crash-* -minimize_crash=1`, then file
the repro in SECURITY-FINDINGS.md.

Artifact triage policy (`fuzz/artifacts/`, gitignored): `crash-*`,
`oom-*` and `timeout-*` files are unfixed findings and fail both
`ci/jobs/fuzz-regress.sh` and `tests/t/20-fuzz-corpus.sh` until they
are triaged — fixed bugs move to `tests/data/crashers/<target>/` or a
named seed in `fuzz/corpus/<target>/`; by-design performance cases are
renamed `slow-unit-*`, which both gates only report (see
SECURITY-FINDINGS.md for the s///g amplification note).  Do not seed
inherently slow inputs into `fuzz/corpus/`: every campaign replays the
corpus once at startup under `-timeout=25`, and every deterministic
replay re-executes them.

Named seeds in the corpora (e.g. `slow-awkb-nested-bounds-1`,
`regsub-null-dst-ubsan`, `overflow-*`) are minimized reproducers kept
for regression; they replay fine after their fixes.
