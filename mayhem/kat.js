// mayhem/kat.js — deterministic known-answer probe used by mayhem/test.sh.
//
// WHY this exists (see test.sh header for the full rationale): upstream's own tests/test_*.js
// files are genuine assert()-based behavioral tests, but every one of them is SILENT on success
// (they only print/throw on FAILURE) and `./qjs` is dynamically linked, so under the verify-repo
// sabotage shim (LD_PRELOAD _exit(0) on process start) a "run the script, check exit==0" oracle
// is indistinguishable from a real pass -- exit 0 either way. That is exactly the exit-code-only
// trap the spec forbids (SPEC §6.3).
//
// This probe instead PRINTS the value of each computation immediately after computing it, and
// mayhem/test.sh grep -x's for the EXACT expected line. A neutered qjs prints nothing (process
// never reaches this code) -> every expected line fails to match -> the sabotage check correctly
// flags a difference from the normal run. A patch that breaks the computation prints a WRONG
// value -> the exact-match grep still fails. Only a genuinely correct, executing interpreter
// produces all six expected lines.
//
// No file I/O, no upstream imports -- self-contained so it needs no fixtures.

function assertEq(actual, expected, name) {
    if (!Object.is(actual, expected)) {
        throw new Error("KAT assertion failed: " + name + " got |" + actual + "| expected |" + expected + "|");
    }
}

// 1) Arithmetic / function calls.
var arith = (function (a, b) { return a * b; })(6, 7);
console.log("KAT_ARITH=" + arith);
assertEq(arith, 42, "ARITH");

// 2) RegExp match (libregexp, same engine fuzz_regexp drives directly).
var reMatch = /^[a-z]+\d+$/.test("quickjs42");
console.log("KAT_REGEXP_MATCH=" + reMatch);
assertEq(reMatch, true, "REGEXP_MATCH");

// 3) RegExp replace with capture groups.
var reReplace = "2024-01-02".replace(/(\d+)-(\d+)-(\d+)/, "$3/$2/$1");
console.log("KAT_REGEXP_REPLACE=" + reReplace);
assertEq(reReplace, "02/01/2024", "REGEXP_REPLACE");

// 4) JSON parse/stringify round-trip (the JSON builtin fuzz_compile/fuzz_eval both reach).
var jsonRT = JSON.stringify(JSON.parse('{"a":[1,2,3],"b":"x"}'));
console.log("KAT_JSON=" + jsonRT);
assertEq(jsonRT, '{"a":[1,2,3],"b":"x"}', "JSON");

// 5) BigInt arithmetic (a distinct numeric representation from doubles).
var fact20 = 1n;
for (var i = 2n; i <= 20n; i++) fact20 *= i;
console.log("KAT_BIGINT_FACT20=" + fact20.toString());
assertEq(fact20.toString(), "2432902008176640000", "BIGINT_FACT20");

// 6) UTF-16 surrogate-pair handling (unicode support in the string engine).
var unicodeLen = "\u{1F600}".length;
console.log("KAT_UNICODE_LEN=" + unicodeLen);
assertEq(unicodeLen, 2, "UNICODE_LEN");

console.log("KAT_ALL_PASSED=1");
