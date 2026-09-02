#!/usr/bin/env bash
# coverage.sh — line coverage for tools/ and hooks/, from the test suite.
#
#   tests/coverage.sh              a table on stdout
#   tests/coverage.sh --markdown   the same as a Markdown table (CI summaries)
#   tests/coverage.sh --min 30     also fail if total coverage is under 30%
#
# How it works: bash writes an xtrace line per command, and `PS4` can carry
# `${BASH_SOURCE}:${LINENO}`. Pointing `BASH_ENV` at a stub that turns both on
# instruments every tool the suite runs — each is a `#!/usr/bin/env bash`
# script, so its shell sources `BASH_ENV` on startup. Nothing on disk is
# modified, which matters: injecting a preamble would shift every line number,
# and `agent-env.sh --help` prints its own header by line range.
#
# Requires bash >= 4.1 for BASH_XTRACEFD, without which the trace lands on
# stderr and corrupts everything that reads it. macOS ships bash 3.2, so this
# is a Linux/CI tool; on macOS, run it in a container.
#
# Known blind spot: `env -i` wipes BASH_ENV, so the tools invoked that way are
# not traced. agent_env_test.sh does exactly that, deliberately — a controlled
# environment is the point of those cases — so `tools/agent-env.sh` reports
# lower here than it really is (26% measured this way, 52% when measured by
# injecting the preamble into each file instead). The under-report is the
# price of not rewriting the scripts under test, which is the right trade:
# injection shifts every line number, and `agent-env.sh --help` prints its own
# header by line range. Read that one row as a floor, not a figure.
set -uo pipefail

markdown=no
min=""
while [ $# -gt 0 ]; do
  case "$1" in
    --markdown) markdown=yes; shift ;;
    --min) min="${2:?--min needs a percentage}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

tests_dir="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$tests_dir/.." && pwd)"

if [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 1 ]; }; then
  {
    echo "error: needs bash >= 4.1 for BASH_XTRACEFD (this is ${BASH_VERSION})"
    echo "       macOS ships 3.2. Run it in a container instead:"
    echo "       docker run --rm -v \"\$PWD:/src:ro\" -w /work ubuntu:24.04 bash -lc '"
    echo "         apt-get update -qq && apt-get install -y -qq git python3 >/dev/null &&"
    echo "         cp -R /src/. /work/ && rm -f /work/.git && tests/coverage.sh'"
  } >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "error: needs python3 to read the trace" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/wtc-cov.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trace="$work/trace.log"
: > "$trace"

cat > "$work/on.sh" <<EOF
exec 9>>$trace 2>/dev/null || true
BASH_XTRACEFD=9
PS4='@@\${BASH_SOURCE}:\${LINENO}@@ '
set -x
EOF

# Two runs. The clean one is the truth about whether the suite passes; the
# instrumented one is only a measurement. `set -x` perturbs a few assertions
# that match on captured output, so the report states that delta rather than
# pretending there is none — a coverage number quietly produced by a redder
# suite than the one gating CI is worth knowing about.
clean_tally="$(cd "$root" && tests/run.sh </dev/null 2>&1 | tail -1)"
inst_tally="$(cd "$root" && BASH_ENV="$work/on.sh" tests/run.sh </dev/null 2>&1 | tail -1)"

MARKDOWN="$markdown" MIN="$min" TRACE="$trace" ROOT="$root" \
CLEAN="$clean_tally" INST="$inst_tally" python3 <<'PY'
import os, re, collections, pathlib, sys

root = pathlib.Path(os.environ["ROOT"])
md   = os.environ["MARKDOWN"] == "yes"
mn   = os.environ["MIN"].strip()

hits = collections.defaultdict(set)
pat  = re.compile(r"@@(\S+?):(\d+)@@")
for line in open(os.environ["TRACE"], errors="replace"):
    for m in pat.finditer(line):
        hits[os.path.basename(m.group(1))].add(int(m.group(2)))

# Executable lines, approximately: not blank, not a comment, and not a line
# that is only shell structure. bash emits no trace for `fi`, `done`, `esac`
# and friends, so counting them would understate every script by the depth of
# its own nesting.
STRUCT = {"fi", "done", "esac", "else", "}", "{", ";;", "then", "do", "fi;", "esac;"}

def executable(path):
    out = set()
    for i, raw in enumerate(path.read_text().splitlines(), 1):
        s = raw.strip()
        if s and not s.startswith("#") and s not in STRUCT:
            out.add(i)
    return out

rows, tot_hit, tot_exe = [], 0, 0
for d in ("tools", "hooks"):
    for f in sorted((root / d).glob("*.sh")):
        ex = executable(f)
        h  = hits.get(f.name, set()) & ex
        rows.append((f"{d}/{f.name}", len(h), len(ex)))
        tot_hit += len(h)
        tot_exe += len(ex)

rows.sort(key=lambda r: (r[1] / r[2] if r[2] else 0))
pct   = lambda h, e: (100.0 * h / e) if e else 0.0
total = pct(tot_hit, tot_exe)

def tally(s):
    p = re.search(r"(\d+) passed", s or "")
    f = re.search(r"(\d+) failed", s or "")
    return (int(p.group(1)) if p else 0, int(f.group(1)) if f else 0)

clean_pass, clean_fail = tally(os.environ["CLEAN"])
inst_pass,  inst_fail  = tally(os.environ["INST"])

if md:
    print("### Line coverage\n")
    print(f"**{total:.0f}%** — {tot_hit} of {tot_exe} executable lines, "
          f"across {len(rows)} scripts.\n")
    print("| script | covered | executable | % |")
    print("|---|---:|---:|---:|")
    for n, h, e in rows:
        print(f"| `{n}` | {h} | {e} | {pct(h, e):.0f}% |")
    print(f"| **total** | **{tot_hit}** | **{tot_exe}** | **{total:.0f}%** |")
    print()
    print(f"Suite: **{clean_pass} passed / {clean_fail} failed** clean.")
    if (inst_pass, inst_fail) != (clean_pass, clean_fail):
        print(f"Under instrumentation: {inst_pass} passed / {inst_fail} failed — "
              "`set -x` perturbs assertions that match on captured output. "
              "CI gates on the clean run; this job only measures.")
else:
    print(f"{'script':<28} {'covered':>8} {'exec':>6} {'%':>6}")
    print("-" * 52)
    for n, h, e in rows:
        print(f"{n:<28} {h:>8} {e:>6} {pct(h, e):>5.0f}%")
    print("-" * 52)
    print(f"{'TOTAL':<28} {tot_hit:>8} {tot_exe:>6} {total:>5.0f}%")
    print()
    print(f"suite: {clean_pass} passed / {clean_fail} failed (clean)")
    if (inst_pass, inst_fail) != (clean_pass, clean_fail):
        print(f"       {inst_pass} passed / {inst_fail} failed (instrumented — "
              "set -x perturbs output-matching assertions)")

if mn:
    floor = float(mn)
    if total < floor:
        print(f"\nerror: coverage {total:.1f}% is below the {floor:.0f}% floor", file=sys.stderr)
        sys.exit(1)
PY
