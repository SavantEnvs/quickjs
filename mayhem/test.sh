#!/usr/bin/env bash
#
# mayhem/test.sh — RUN QuickJS's own functional test suite (already built by mayhem/build.sh,
# the PLAIN, non-sanitized `./qjs`) plus a known-answer probe, and emit a CTRF summary.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the load-bearing one:
#
#  1) upstream's tests/test_*.js -- genuine assert()-based regression tests (each script defines
#     its own local `assert(actual, expected, msg)` and THROWS on mismatch), covering closures,
#     core language semantics, builtins, loops, BigInt, cyclic ES module imports, Workers, the std
#     module, and the read/write handler API. A real functional regression (broken arithmetic,
#     broken Proxy trap, wrong typed-array bounds, ...) makes one of these throw -> qjs exits
#     non-zero -> counted as a failure below.
#
#  2) mayhem/kat.js -- because every one of those scripts is SILENT on success (they only print on
#     failure) and `./qjs` is dynamically linked, a plain "run it, check exit==0" oracle is exactly
#     the exit-code-only trap SPEC §6.3 forbids: the verify-repo sabotage shim (LD_PRELOAD, _exit(0)
#     at process start) makes qjs exit 0 having done NOTHING, indistinguishable from a real pass.
#     mayhem/kat.js instead PRINTs each computed value immediately ("KAT_NAME=value"), and this
#     script greps for the EXACT expected line. A neutered qjs prints nothing -> every expected
#     line is missing -> detected. A patch that breaks the computation prints a WRONG value ->
#     still detected (exact match, not just "did it crash"). See mayhem/kat.js's header for why
#     each of its six checks was chosen.
#
# This script only RUNS things; mayhem/build.sh did the building. Fails loudly (not silently) if
# the oracle binary is missing -- that's a build.sh bug, never something to skip past.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASSED=0; FAILED=0

QJS="$SRC/qjs"
if [ ! -x "$QJS" ]; then
  echo "FATAL: $QJS not found -- mayhem/build.sh should have built the oracle interpreter" >&2
  emit_ctrf "qjs-tests+kat" 0 1 0
  exit 1
fi

# ── 1) upstream's own assert()-based regression scripts ─────────────────────────────
run_script() {
  local name="$1"; shift
  echo "=== running: qjs $* ==="
  # NB: no pipe to `tee` here -- `if cmd | tee ...` would check tee's exit status (always 0),
  # not qjs's, silently turning every failure into a reported pass.
  if "$QJS" "$@" > "$SRC/mayhem-test-$name.log" 2>&1; then
    cat "$SRC/mayhem-test-$name.log"
    echo "PASS: $name"
    PASSED=$(( PASSED + 1 ))
  else
    cat "$SRC/mayhem-test-$name.log" >&2
    echo "FAIL: $name" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

run_script test_closure        tests/test_closure.js
run_script test_language       tests/test_language.js
run_script test_builtin        --std tests/test_builtin.js
run_script test_loop           tests/test_loop.js
run_script test_bigint         tests/test_bigint.js
run_script test_cyclic_import  tests/test_cyclic_import.js
run_script test_worker         tests/test_worker.js
run_script test_std            tests/test_std.js
run_script test_rw_handler     tests/test_rw_handler.js

# ── 2) the KAT probe (sabotage-detecting; see header) ────────────────────────────────
# UNCONDITIONAL by design: a missing script or wrong value is a FAILURE, never a skip. A
# `[ -f ... ]` guard here is how a probe silently stops running and the oracle quietly
# degrades to the script-exit-code-only (reward-hackable) case.
echo "=== KAT probe: qjs mayhem/kat.js (asserts EXACT printed values) ==="
KAT_OUT="$("$QJS" mayhem/kat.js 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label -- expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: qjs mayhem/kat.js exited $kat_rc (neutered, missing, or interpreter broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
kat_expect "arithmetic"        'KAT_ARITH=42'
kat_expect "regexp match"      'KAT_REGEXP_MATCH=true'
kat_expect "regexp replace"    'KAT_REGEXP_REPLACE=02/01/2024'
kat_expect "JSON round-trip"   'KAT_JSON={"a":[1,2,3],"b":"x"}'
kat_expect "BigInt 20!"        'KAT_BIGINT_FACT20=2432902008176640000'
kat_expect "UTF-16 surrogate"  'KAT_UNICODE_LEN=2'
kat_expect "all checks ran"    'KAT_ALL_PASSED=1'

emit_ctrf "qjs-tests+kat" "$PASSED" "$FAILED"
