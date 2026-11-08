#!/bin/sh
#
# run-diff.sh — differential test runner for cragutils (PLAN.md P9).
#
# Runs a corpus of real and edge-case invocations against every available
# userland implementation and compares the results:
#
#   cragutils  the tools this tree builds (a meson build tree or flat bindir)
#   gnu        the host's GNU (or whatever) tools in /usr/bin
#   freebsd    a real FreeBSD userland via tests/diff/oracle/run-on-freebsd.sh
#              (skip-if-absent — the oracle is built separately)
#
# Comparison semantics per case (see tests/diff/README.md):
#   - stdout: strict byte comparison after applying the case's explicit
#     normalization hints (never fuzzy matching)
#   - exit status: strict
#   - stderr: present/absent only (message wording legitimately differs
#     between BSD and GNU)
#
# Verdict classes (PLAN.md P9 policy — FreeBSD is the reference):
#   MATCH           cragutils agrees with FreeBSD (and with GNU)
#   DECLARED_DELTA  cragutils-vs-FreeBSD mismatch explained by a
#                   DIFFERENCES/ entry named in the case's delta: hint
#   DRIFT           undeclared cragutils-vs-FreeBSD mismatch — the ONLY
#                   gate-failing class
#   GNU_DIVERGENCE  cragutils matches FreeBSD (or FreeBSD is not being
#                   compared) but differs from GNU — documentation only
#   SKIP            no comparable backend ran the case
#
# Usage:
#   tests/diff/run-diff.sh                     # auto-detect build-meson
#   tests/diff/run-diff.sh --build DIR         # meson build tree
#   tests/diff/run-diff.sh --bindir DIR        # flat directory of tools
#   tests/diff/run-diff.sh --backends cragutils,gnu
#   tests/diff/run-diff.sh --tool sort --tool cut
#   tests/diff/run-diff.sh --list
#
# Options:
#   --build DIR      meson/ninja build tree to take cragutils tools from
#   --bindir DIR     flat directory containing the cragutils tools
#   --backends LIST  comma-separated subset of cragutils,gnu,freebsd
#   --tool NAME      only run cases for this tool (repeatable)
#   --cases DIR      corpus directory (default: tests/diff/cases)
#   --junit PATH     junit XML output (default: build/state/test-results/diff.xml)
#   --report PATH    human report output in addition to stdout
#                    (default: build/state/test-results/diff.txt)
#   --timeout N      per-run timeout in seconds (default 10)
#   --keep-work      keep the scratch tree
#   --quiet          only report the summary and non-MATCH verdicts
#   --list           list corpus tools and case counts, then exit
#
# Exit status: 0 no DRIFT, 1 DRIFT found, 2 usage/setup error.

set -u

srcdir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
diffdir=$srcdir/tests/diff
cases_dir=$diffdir/cases

build=
bindir=
backends=cragutils,gnu,freebsd
tools_filter=
junit_path=$srcdir/build/state/test-results/diff.xml
report_path=$srcdir/build/state/test-results/diff.txt
timeout_s=10
keep_work=0
quiet=0
list=0

while [ $# -gt 0 ]; do
    case $1 in
        --build)    build=$2; shift 2 ;;
        --bindir)   bindir=$2; shift 2 ;;
        --backends) backends=$2; shift 2 ;;
        --tool)     tools_filter="$tools_filter $2"; shift 2 ;;
        --cases)    cases_dir=$2; shift 2 ;;
        --junit)    junit_path=$2; shift 2 ;;
        --report)   report_path=$2; shift 2 ;;
        --timeout)  timeout_s=$2; shift 2 ;;
        --keep-work) keep_work=1; shift ;;
        --quiet|-q) quiet=1; shift ;;
        --list)     list=1; shift ;;
        -h|--help)  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) printf 'run-diff.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
        *)  printf 'run-diff.sh: unexpected argument %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [ $list -eq 1 ]; then
    total=0
    for f in "$cases_dir"/*.cases; do
        [ -f "$f" ] || continue
        n=$(grep -cv -e '^#' -e '^$' "$f")
        printf '%-12s %3d cases\n' "$(basename "$f" .cases)" "$n"
        total=$((total + n))
    done
    printf '%-12s %3d cases\n' total "$total"
    exit 0
fi

# ---------------------------------------------------------------------
# Locate the cragutils tools
# ---------------------------------------------------------------------

work_root=${CU_DIFF_WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/cragutils-diff.XXXXXX")}
mkdir -p "$work_root"
cleanup() {
    [ "$keep_work" = "1" ] || rm -rf "$work_root"
}
trap cleanup EXIT INT TERM

cu_bin=
if [ -n "$bindir" ]; then
    bindir=$(CDPATH= cd -- "$bindir" && pwd)
    cu_bin=$bindir
elif [ -n "$build" ] || [ -f "$srcdir/build-meson/build.ninja" ]; then
    build=${build:-$srcdir/build-meson}
    build=$(CDPATH= cd -- "$build" && pwd)
    # Meson puts each tool in its own subdirectory alongside a <tool>.p
    # object directory; skip those, the private dirs and shared objects.
    # Same scan as tests/run-tests.sh; link flat so the tool name is the
    # basename (usage messages print argv[0]'s basename either way).
    cu_bin=$work_root/cu-bin
    mkdir -p "$cu_bin"
    find "$build" -type f -perm -u+x \
        ! -path '*.p/*' ! -path '*meson-private*' \
        ! -name '*.so' ! -name '*.so.*' ! -name '*.a' ! -name '*.exe' \
        2>/dev/null |
    while IFS= read -r f; do
        ln -sf "$f" "$cu_bin/$(basename "$f")" 2>/dev/null || true
    done
else
    printf 'run-diff.sh: no cragutils build found; pass --build or --bindir\n' >&2
    exit 2
fi

# The GNU backend is whatever the host calls its own tools.
gnu_bin=/usr/bin
oracle=$diffdir/oracle/run-on-freebsd.sh

# Sanitizers and qemu-user runtimes: sandboxed tools fail by design there
# (same guard as tests/run-tests.sh).
if [ -z "${CRAGUTILS_SANDBOX:-}" ] && [ -x "$cu_bin/shimtest" ]; then
    ( cd "$work_root" && "$cu_bin/shimtest" ) >/dev/null 2>&1
    if [ $? -eq 77 ]; then
        CRAGUTILS_SANDBOX=NONE
        export CRAGUTILS_SANDBOX
    fi
fi

have_backend() {
    case ",$backends," in *",$1,"*) return 0 ;; esac
    return 1
}

backend_note=freebsd:present
if have_backend freebsd && [ ! -x "$oracle" ]; then
    backend_note=freebsd:skipped-no-oracle
fi

# ---------------------------------------------------------------------
# Case parsing: 5 tab-separated fields (tests/diff/README.md)
#   id  argv  stdin  env  hints
# ---------------------------------------------------------------------

d_id=; d_argv=; d_stdin=; d_env=; d_hints=

load_case() {
    d_id=$1
    d_argv=$2
    d_stdin=$3
    d_env=$4
    d_hints=$5
}

# hint_has <prefix> — true when the hints field contains a matching token.
hint_has() {
    old_ifs=$IFS; IFS=,
    for _h in $d_hints; do
        case $_h in "$1"*) IFS=$old_ifs; return 0 ;; esac
    done
    IFS=$old_ifs
    return 1
}

hint_val() {
    old_ifs=$IFS; IFS=,
    for _h in $d_hints; do
        case $_h in "$1"*) printf '%s' "${_h#*:}"; IFS=$old_ifs; return 0 ;; esac
    done
    IFS=$old_ifs
    return 0
}

# normalize <file> <workdir> <toolpath> — apply the case's explicit
# normalization hints in place.  Hints are explicit tokens only:
#   norm:workdir   replace the run's scratch directory path with <WORKDIR>
#   norm:toolpath  replace the tool's absolute path with <TOOL>
#   norm:epoch     replace maximal runs of exactly 10 digits with <EPOCH>
#   norm:sortlines sort the output lines (find traversal order etc.)
normalize() {
    _nf=$1; _wd=$2; _tp=$3
    if hint_has norm:workdir; then
        _pat=$(printf '%s' "$_wd" | sed 's/[][\\.*^$|/]/\\&/g')
        sed "s|$_pat|<WORKDIR>|g" "$_nf" > "$_nf.n" && mv "$_nf.n" "$_nf"
    fi
    if hint_has norm:toolpath; then
        _pat=$(printf '%s' "$_tp" | sed 's/[][\\.*^$|/]/\\&/g')
        sed "s|$_pat|<TOOL>|g" "$_nf" > "$_nf.n" && mv "$_nf.n" "$_nf"
    fi
    if hint_has norm:epoch; then
        awk '{
            s = $0; out = ""
            while (match(s, /[0-9]+/)) {
                out = out substr(s, 1, RSTART - 1)
                num = substr(s, RSTART, RLENGTH)
                if (length(num) == 10) out = out "<EPOCH>"; else out = out num
                s = substr(s, RSTART + RLENGTH)
            }
            print out s
        }' "$_nf" > "$_nf.n" && mv "$_nf.n" "$_nf"
    fi
    if hint_has norm:sortlines; then
        LC_ALL=C sort "$_nf" > "$_nf.n" && mv "$_nf.n" "$_nf"
    fi
}

# post_obs <rundir> — append the explicit post:<path> observations (file
# size + sha256, or MISSING) to the run's observation file.
post_obs() {
    _rd=$1
    old_ifs=$IFS; IFS=,
    for _h in $d_hints; do
        case $_h in
            post:*)
                _p=${_h#post:}
                if [ -f "$_rd/w/$_p" ]; then
                    _sz=$(wc -c < "$_rd/w/$_p" | tr -d ' ')
                    _sh=$(sha256sum < "$_rd/w/$_p" | cut -c1-64)
                    printf 'post:%s size=%s sha256=%s\n' "$_p" "$_sz" "$_sh"
                elif [ -d "$_rd/w/$_p" ]; then
                    printf 'post:%s DIR\n' "$_p"
                else
                    printf 'post:%s MISSING\n' "$_p"
                fi >> "$_rd/obs" ;;
        esac
    done
    IFS=$old_ifs
}

# run_backend <backend> <tool> — run the loaded case; outputs live in
# $work_root/runs/<backend>/<tool>/<id>/  (exit, out, err, obs).
# Returns 0 when the case ran, 1 when the backend lacks the tool.
run_backend() {
    _be=$1; _tool=$2
    _rd=$work_root/runs/$_be/$_tool/$d_id
    rm -rf "$_rd"
    mkdir -p "$_rd"

    case $_be in
        cragutils) _tp=$cu_bin/$_tool; _pp=$cu_bin:/usr/bin:/bin ;;
        gnu)       _tp=$gnu_bin/$_tool; _pp=/usr/bin:/bin ;;
        freebsd)   _tp=freebsd:$_tool; _pp=/usr/bin:/bin ;;
    esac

    if [ "$_be" = freebsd ]; then
        [ -x "$oracle" ] || return 1
    else
        [ -x "$_tp" ] || return 1
    fi

    # Fixtures: cases/<tool>.d/<id>/ is copied into the run's working
    # directory ($_rd/w).  Harness artifacts (out/err/obs/exit) live one
    # level up so they never appear in the tool's view of its cwd — the
    # oracle-side tree is exactly the tar of w/.
    mkdir -p "$_rd/w"
    if [ -d "$cases_dir/$_tool.d/$d_id" ]; then
        cp -R "$cases_dir/$_tool.d/$d_id/." "$_rd/w/" 2>/dev/null || true
    fi

    # Pin fixture mtimes: scratch mtimes are artifacts of when the case
    # ran, not tool behavior, and would poison mtime-bearing output
    # (stat, date -r, find -newermt) with run-to-run noise.
    find "$_rd/w" -exec touch -t 202601010000.00 {} + 2>/dev/null || true

    # Stdin: '-' empty, '@path' file relative to cases/<tool>.d/, else
    # an inline literal with \n \t \\ escapes.
    case $d_stdin in
        -)  _sf=/dev/null ;;
        @*) _sf=$cases_dir/$_tool.d/${d_stdin#@} ;;
        *)  printf '%b' "$d_stdin" > "$_rd/stdin"; _sf=$_rd/stdin ;;
    esac

    # Environment: a minimal deterministic base plus the case's deltas.
    _ev="LC_ALL=C TZ=UTC HOME=$_rd"
    if [ "$d_env" != "-" ]; then
        _ev="$_ev $d_env"
    fi

    : > "$_rd/obs"
    if [ "$_be" = freebsd ]; then
        _oe=""
        if [ "$d_env" != "-" ]; then
            old_ifs=$IFS; IFS=' '
            for _e in $d_env; do
                _oe="$_oe --env $_e"
            done
            IFS=$old_ifs
        fi
        # shellcheck disable=SC2086
        tar -cf "$work_root/tree-$d_id.tar" -C "$_rd/w" . 2>/dev/null || true
        ( cd "$_rd/w" && eval "set -- $d_argv" &&
          { case ${1:-} in "$_tool") shift ;; esac; } &&
          "$oracle" --stdin "$_sf" --tar "$work_root/tree-$d_id.tar" \
              $_oe -- "$_tool" "$@" ) \
            > "$_rd/frame" 2> "$_rd/runner-err"
        _fr=$?
        if [ "$_fr" -eq 77 ]; then
            rm -rf "$_rd"
            return 1
        fi
        if ! oracle_unframe "$_rd"; then
            printf 'oracle frame could not be parsed; case skipped\n' > "$_rd/err"
            echo 255 > "$_rd/exit"
            rm -rf "$_rd"
            return 1
        fi
    else
        _tp_save=$_tp
        (
            cd "$_rd/w" || exit 255
            umask 022
            # shellcheck disable=SC2086
            eval "set -- $d_argv"
            # The argv field is the full invocation, tool name included
            # (harvest style); the backend's binary replaces that first
            # word.
            case ${1:-} in "$_tool") shift ;; esac
            if command -v timeout >/dev/null 2>&1; then
                # shellcheck disable=SC2086
                exec env -i PATH="$_pp" $_ev timeout "$timeout_s" \
                    "$_tp_save" "$@" < "$_sf" > "$_rd/out" 2> "$_rd/err"
            else
                # shellcheck disable=SC2086
                exec env -i PATH="$_pp" $_ev \
                    "$_tp_save" "$@" < "$_sf" > "$_rd/out" 2> "$_rd/err"
            fi
        )
        echo $? > "$_rd/exit"
    fi

    post_obs "$_rd"
    normalize "$_rd/out" "$_rd/w" "$_tp"
    return 0
}

# oracle_unframe <rundir> — parse the oracle's framed record into
# exit/out/err files.  The frame contract is documented in
# tests/diff/oracle/README.md.  Returns 1 on a malformed record.
oracle_unframe() {
    _rd=$1
    _f=$_rd/frame
    [ -f "$_f" ] || return 1
    _off=1
    _line=$(dd if="$_f" bs=1 count=200 2>/dev/null | sed -n 1p)
    case $_line in
        'CRAG-ORACLE 1'|'crag-oracle-v1'|CRAG-ORACLE*) : ;;
        *) return 1 ;;
    esac
    _off=$((_off + ${#_line} + 1))

    _exit=; _slen=; _elen=
    for _i in 1 2 3; do
        _line=$(dd if="$_f" bs=1 skip="$_off" count=200 2>/dev/null | sed -n 1p)
        _off=$((_off + ${#_line} + 1))
        case $_line in
            exit:*|exit\ *|status:*)        _exit=${_line#*:}; _exit=${_exit# } ;;
            stdout-bytes:*|stdout-len:*|stdout:*)
                _slen=${_line#*:}; _slen=${_slen# } ;;
            stderr-bytes:*|stderr-len:*|stderr:*)
                _elen=${_line#*:}; _elen=${_elen# } ;;
            *) return 1 ;;
        esac
    done
    case $_exit in ''|*[!0-9]*) return 1 ;; esac
    case $_slen in ''|*[!0-9]*) return 1 ;; esac
    case $_elen in ''|*[!0-9]*) return 1 ;; esac

    printf '%s\n' "$_exit" > "$_rd/exit"
    dd if="$_f" bs=1 skip="$_off" count="$_slen" of="$_rd/out" 2>/dev/null
    _off=$((_off + _slen))
    dd if="$_f" bs=1 skip="$_off" count="$_elen" of="$_rd/err" 2>/dev/null
    : > "$_rd/obs"
    return 0
}

# ---------------------------------------------------------------------
# Comparison and verdicts
# ---------------------------------------------------------------------

# stderr_present <file> — 1 when the file has content.
stderr_present() {
    [ -s "$1" ] && printf 1 || printf 0
}

# compare_pair <a-rundir> <b-rundir> — sets cmp_detail; returns 0 when
# identical (stdout bytes + exit status strict, stderr presence only).
compare_pair() {
    _a=$1; _b=$2
    cmp_detail=
    _same=1

    cat "$_a/out" "$_a/obs" > "$_a/cmp"
    cat "$_b/out" "$_b/obs" > "$_b/cmp"
    if ! cmp -s "$_a/cmp" "$_b/cmp"; then
        _same=0
        cmp_detail="stdout differs"
    fi

    _ea=$(cat "$_a/exit"); _eb=$(cat "$_b/exit")
    if [ "$_ea" != "$_eb" ]; then
        _same=0
        cmp_detail="$cmp_detail; exit $_ea/$_eb"
    fi

    _sa=$(stderr_present "$_a/err"); _sb=$(stderr_present "$_b/err")
    if [ "$_sa" != "$_sb" ]; then
        _same=0
        cmp_detail="$cmp_detail; stderr $_sa/$_sb (present=1)"
    fi

    [ "$_same" -eq 1 ] && cmp_detail="exit $_ea, stdout identical, stderr $_sa/$_sb"
    [ "$_same" -eq 1 ]
}

# delta_declared <tool> — true when the case's delta: hint names a real
# DIFFERENCES/ heading (substring match against the heading lines).
delta_declared() {
    _tool=$1
    _slug=$(hint_val delta:)
    [ -n "$_slug" ] || return 1
    [ -f "$srcdir/DIFFERENCES" ] || return 1
    awk -v slug="$_slug" '
        prev != "" && /^-{3,}$/ && index(tolower(prev), tolower(slug)) {
            found = 1; exit
        }
        { prev = $0 }
        END { exit found ? 0 : 1 }
    ' "$srcdir/DIFFERENCES"
}

# diff_excerpt <a-rundir> <b-rundir> — short unified diff for the report.
diff_excerpt() {
    diff -u "$1/cmp" "$2/cmp" 2>/dev/null | sed -n '3,10p'
}

# ---------------------------------------------------------------------
# Run the corpus
# ---------------------------------------------------------------------

printf 'cragutils differential report\n'
printf '  corpus:    %s\n' "$cases_dir"
printf '  cragutils: %s\n' "${cu_bin:-none}"
printf '  gnu:       %s%s\n' "$gnu_bin" \
    "$(have_backend gnu && [ ! -x "$gnu_bin" ] && printf ' (absent)')"
printf '  freebsd:   %s\n' "$backend_note"
printf '  work:      %s\n\n' "$work_root"

results=$work_root/results.tsv
: > "$results"

n_total=0
for cf in "$cases_dir"/*.cases; do
    [ -f "$cf" ] || continue
    tool=$(basename "$cf" .cases)
    if [ -n "$tools_filter" ]; then
        matched=0
        for pat in $tools_filter; do
            [ "$tool" = "$pat" ] && matched=1
        done
        [ $matched -eq 1 ] || continue
    fi

    while IFS=$(printf '\t') read -r cid cargv cstdin cenv chints || [ -n "$cid" ]; do
        case $cid in ''|'#'*) continue ;; esac
        load_case "$cid" "$cargv" "$cstdin" "$cenv" "$chints"
        n_total=$((n_total + 1))
        label=$tool/$cid

        cu_ok=0; fb_ok=0; gn_ok=0
        have_backend cragutils && run_backend cragutils "$tool" && cu_ok=1
        have_backend freebsd && run_backend freebsd "$tool" && fb_ok=1
        have_backend gnu && run_backend gnu "$tool" && gn_ok=1

        fb_axis=SKIP; gn_axis=SKIP; verdict=SKIP; detail=

        if [ $cu_ok -eq 0 ]; then
            detail='tool not built in cragutils'
        else
            cu=$work_root/runs/cragutils/$tool/$cid
            if [ $fb_ok -eq 1 ]; then
                fb=$work_root/runs/freebsd/$tool/$cid
                if compare_pair "$cu" "$fb"; then
                    fb_axis=MATCH
                elif delta_declared "$tool"; then
                    fb_axis=DECLARED_DELTA
                    detail=$cmp_detail
                else
                    fb_axis=DRIFT
                    detail=$cmp_detail
                fi
            fi
            if [ $gn_ok -eq 1 ]; then
                gn=$work_root/runs/gnu/$tool/$cid
                if compare_pair "$cu" "$gn"; then
                    gn_axis=MATCH
                else
                    gn_axis=GNU_DIVERGENCE
                    [ -n "$detail" ] || detail=$cmp_detail
                    detail="$detail [gnu: $cmp_detail]"
                fi
            fi

            case $fb_axis in
                DRIFT)          verdict=DRIFT ;;
                DECLARED_DELTA) verdict=DECLARED_DELTA ;;
                MATCH)
                    [ "$gn_axis" = GNU_DIVERGENCE ] && verdict=GNU_DIVERGENCE
                    [ "$gn_axis" = MATCH ] && verdict=MATCH
                    [ "$gn_axis" = SKIP ] && verdict=MATCH
                    ;;
                SKIP)
                    [ "$gn_axis" = GNU_DIVERGENCE ] && verdict=GNU_DIVERGENCE
                    [ "$gn_axis" = MATCH ] && verdict=MATCH
                    ;;
            esac
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$tool" "$cid" "$verdict" "$fb_axis" "$gn_axis" "$d_argv" "$detail" \
            >> "$results"

        if [ $quiet -eq 0 ] || [ "$verdict" != MATCH ]; then
            printf '  %-14s %-15s fb=%-13s gnu=%s\n' \
                "$label" "$verdict" "$fb_axis" "$gn_axis" | tee -a "$work_root/report-lines"
            if [ "$verdict" != MATCH ] && [ -n "$detail" ]; then
                printf '      %s\n' "$detail" | tee -a "$work_root/report-lines"
            fi
            if [ "$verdict" = DRIFT ] || [ "$verdict" = GNU_DIVERGENCE ]; then
                if [ $fb_ok -eq 1 ] && [ "$fb_axis" != MATCH ] && [ "$fb_axis" != SKIP ]; then
                    diff_excerpt "$work_root/runs/cragutils/$tool/$cid" \
                        "$work_root/runs/freebsd/$tool/$cid" |
                        sed 's/^/      | /' | tee -a "$work_root/report-lines"
                elif [ $gn_ok -eq 1 ]; then
                    diff_excerpt "$work_root/runs/cragutils/$tool/$cid" \
                        "$work_root/runs/gnu/$tool/$cid" |
                        sed 's/^/      | /' | tee -a "$work_root/report-lines"
                fi
            fi
        fi
    done < "$cf"
done

# ---------------------------------------------------------------------
# Summary, junit XML
# ---------------------------------------------------------------------

count() { awk -F'\t' -v v="$1" '$3 == v { n++ } END { print n + 0 }' "$results"; }
n_match=$(count MATCH)
n_delta=$(count DECLARED_DELTA)
n_drift=$(count DRIFT)
n_gnu=$(count GNU_DIVERGENCE)
n_skip=$(count SKIP)

printf '\n----------------------------------------\n'
printf '%s cases: %s MATCH, %s DECLARED_DELTA, %s GNU_DIVERGENCE, %s DRIFT, %s SKIP\n' \
    "$n_total" "$n_match" "$n_delta" "$n_gnu" "$n_drift" "$n_skip"
printf 'per-tool:\n'
awk -F'\t' '{ n[$1]++; v[$1" "$3]++ }
    END { for (t in n) printf "  %-12s %3d cases  (match %d, delta %d, gnu %d, drift %d, skip %d)\n",
        t, n[t], v[t" MATCH"]+0, v[t" DECLARED_DELTA"]+0,
        v[t" GNU_DIVERGENCE"]+0, v[t" DRIFT"]+0, v[t" SKIP"]+0 }' \
    "$results" | LC_ALL=C sort

mkdir -p "$(dirname "$junit_path")" "$(dirname "$report_path")"
{
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuites>\n'
    printf '  <testsuite name="diff" tests="%s" failures="%s" skipped="%s" time="0">\n' \
        "$n_total" "$n_drift" "$n_skip"
    awk -F'\t' '{
        printf "    <testcase classname=\"diff.%s\" name=\"%s\" time=\"0\">\n", $1, $2
        if ($3 == "DRIFT")
            printf "      <failure message=\"DRIFT (undeclared FreeBSD mismatch): %s\"/>\n", xmls($7)
        if ($3 == "SKIP")
            printf "      <skipped message=\"%s\"/>\n", xmls($7 == "" ? "no comparable backend" : $7)
        printf "      <system-out>verdict=%s freebsd=%s gnu=%s argv=%s detail=%s</system-out>\n", \
            $3, $4, $5, xmls($6), xmls($7)
        printf "    </testcase>\n"
    }
    function xmls(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
    ' "$results"
    printf '  </testsuite>\n'
    printf '</testsuites>\n'
} > "$junit_path"

{
    printf 'cragutils differential report\n'
    printf '  corpus:    %s (%s cases)\n' "$cases_dir" "$n_total"
    printf '  cragutils: %s\n' "${cu_bin:-none}"
    printf '  gnu:       %s\n' "$gnu_bin"
    printf '  freebsd:   %s\n' "$backend_note"
    printf '\n%s cases: %s MATCH, %s DECLARED_DELTA, %s GNU_DIVERGENCE, %s DRIFT, %s SKIP\n' \
        "$n_total" "$n_match" "$n_delta" "$n_gnu" "$n_drift" "$n_skip"
    printf '\ndetail:\n'
    if [ -f "$work_root/report-lines" ]; then
        cat "$work_root/report-lines"
    fi
    printf '\nfull verdicts (tool, case, verdict, freebsd-axis, gnu-axis, argv, detail):\n'
    cat "$results"
} > "$report_path"

printf 'junit:   %s\n' "$junit_path"
printf 'report:  %s\n' "$report_path"

[ "$n_drift" -eq 0 ] || exit 1
exit 0
