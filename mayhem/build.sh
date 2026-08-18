#!/usr/bin/env bash
#
# mayhem/build.sh — build QuickJS's three libFuzzer targets (upstream's own fuzz/*.c,
# also OSS-Fuzz's canonical target set: fuzz_eval, fuzz_compile, fuzz_regexp — see
# oss-fuzz/projects/quickjs/build.sh) plus the plain `qjs` interpreter used as the
# functional-test oracle binary.
#
# Ported from the legacy mayhemheroes/quickjs integration (OSS-Fuzz-base-builder style,
# hand-written fuzz_*.c). Upstream now ships its own fuzz/ dir with a proper `make
# libfuzzer` target and fuzz_common.{c,h} helpers, so we build THOSE (they already do
# JS_SetMaxStackSize + a std/os module loader the legacy harnesses lacked) and only
# reuse the legacy build.sh's insight of the two build passes.
#
# Upstream's Makefile already does the two things the current spec cares about most:
#   - `$(OBJDIR)/%.fuzz.o: %.c` unconditionally adds -fsanitize=fuzzer-no-link, so the
#     LIBRARY (not just the harness TU) is SanCov-instrumented (SPEC §6.2 item 9).
#   - CONFIG_ASAN/CONFIG_MSAN/CONFIG_UBSAN each suffix a DIFFERENT $(OBJDIR) (.obj/asan
#     vs plain .obj), so the sanitized fuzz build and the plain oracle build use
#     SEPARATE object trees with no make-clean dance needed. We only ever pass
#     CONFIG_ASAN=y (see step 2's own comment for why NOT CONFIG_UBSAN=y), so the
#     sanitized tree lands at $(OBJDIR)=.obj/asan.
#
# What we add here: DWARF ≤ 3 (clang's plain -g is DWARF5) and halting UBSan. Both ride
# in via the CFLAGS/LDFLAGS ENVIRONMENT: `CFLAGS+=...`/`LDFLAGS+=...` in the Makefile
# APPENDS to whatever CFLAGS/LDFLAGS already hold, and a variable already set from the
# environment is exactly what a plain (non-command-line) `+=` appends onto — verified
# empirically (`export CFLAGS=-gdwarf-3; make ...` yields CFLAGS="-gdwarf-3 -g -Wall
# ..."). Passing them instead as `make CFLAGS=...` command-line args would NOT work:
# command-line variables silently swallow every subsequent `+=` in the makefile,
# dropping -D_GNU_SOURCE/-fsanitize=address/etc. and breaking the build.
#
# One more thing we work around: upstream's fuzz/fuzz_common.c does NOT build against
# upstream's CURRENT quickjs.h (verified independently of this integration -- a clean
# checkout's `CONFIG_CLANG=y make libfuzzer` fails the same way). It calls the retired
# 3-arg `JS_SetModuleLoaderFunc`, but `js_module_loader` (quickjs-libc.h) was changed to
# the 4-arg `JSModuleLoaderFunc2` shape (import-attributes support) and every other call
# site, including quickjs-libc.c's own js_std_init_handlers(), now pairs it with
# `JS_SetModuleLoaderFunc2` + `js_module_check_attributes`. fuzz_common.c was simply never
# updated. Upstream files are off-limits (additive-only), so mayhem/fuzz_common_fixed.c is
# a same-behavior copy with only that one call corrected -- see its header for the full
# diff. We stage it into fuzz/ under a non-colliding name so it compiles via upstream's
# OWN `$(OBJDIR)/fuzz_%.o: fuzz/fuzz_%.c` pattern rule (same flags upstream would use),
# and link it in place of the broken fuzz_common.o for the two targets that need it
# (fuzz_regexp never references the module loader, so it is unaffected and builds as-is).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${STANDALONE_FUZZ_MAIN:?base image must export STANDALONE_FUZZ_MAIN (LLVM run-once driver)}"
export CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

# Relax ONLY -fsanitize=function (never the rest of the sanitizer set -- ASan and every other
# UBSan check stay halting). quickjs's own cutils.c DynBuf API stores a generic
# `void *(*)(void *, void *, size_t)` realloc callback (DynBufReallocFunc), and every call
# site -- including quickjs.c's own js_realloc_rt(JSRuntime *, void *, size_t) -- registers a
# function whose first parameter is a MORE SPECIFIC pointer type than the generic `void *` the
# typedef declares. That is a completely standard, deliberate C callback-registration idiom
# (same shape as registering any `void *(*)(void *)`-style comparator/allocator), technically
# UB-by-the-letter but not a real bug -- and `-fsanitize=function` fires on it from the FIRST
# dynamic buffer allocation, which happens inside test_one_input_init()'s own std/os bootstrap
# import before a single byte of fuzzer input is even parsed. With `-fno-sanitize-recover=all`
# that makes EVERY run's first `dbuf_claim()` a fatal exit(1) -- fuzz_eval/fuzz_compile could
# not iterate at all (fuzz_regexp is unaffected: its harness wires libregexp straight to a
# plain realloc(), no function-pointer indirection). Textbook "halting UBSan check silently
# starves a target of coverage" (see docs/netnew-worker-prompt.md §6, the xdelta pointer-
# overflow case) -- verified locally: `fuzz_compile -runs=1` on a single "\n" byte exits 1 at
# cutils.c:119 with this exact diagnostic, before this flag was added.
: "${UBSAN_RELAX_FLAGS:=-fno-sanitize=function}"
export UBSAN_RELAX_FLAGS

: "${SRC:=/mayhem}"
cd "$SRC"

# ── 1) Oracle build: the plain `qjs` interpreter, upstream's normal flags, no
#      sanitizers/DWARF3 override. Lands in $(OBJDIR)=.obj (CONFIG_ASAN/UBSAN unset),
#      independent of the sanitized tree built in step 2. mayhem/test.sh only RUNS
#      this — it's a clean, honest functional oracle (see that file's header). ─────
echo "=== [1/3] building oracle: qjs (normal flags) ==="
make -j"$MAYHEM_JOBS" CONFIG_CLANG=y qjs
[ -x ./qjs ] || { echo "FATAL: ./qjs (oracle interpreter) not built" >&2; exit 1; }

# ── 2) Sanitized build: libquickjs.fuzz.a (every library object compiled with
#      -fsanitize=fuzzer-no-link, from upstream's %.fuzz.o pattern rule) + the three
#      upstream libFuzzer harnesses. CFLAGS/LDFLAGS (env, see header) add DWARF3 +
#      halting UBSan. fuzz_common_mayhem.o replaces the broken upstream fuzz_common.o
#      (see header).
#
#      NB: we do NOT pass CONFIG_UBSAN=y here -- the Makefile's own `ifdef CONFIG_UBSAN:
#      CFLAGS+=-fsanitize=undefined` appends AFTER whatever CFLAGS we hand in via the
#      environment (make `+=` always appends), so a `-fno-sanitize=function` placed in
#      OUR CFLAGS would land BEFORE that `-fsanitize=undefined` on the final command
#      line and get silently re-enabled by it (flags apply left-to-right; verified
#      empirically -- this was exactly how the first version of this fix failed). So we
#      supply `-fsanitize=undefined $UBSAN_RELAX_FLAGS` ourselves, in that order, and
#      rely on CONFIG_ASAN=y alone for the `.obj/asan` OBJDIR split from the plain
#      oracle build in step 1 (CONFIG_ASAN's own `-fsanitize=address` addition afterward
#      is a different sanitizer group and does not touch `function`, so it's harmless). ──
echo "=== [2/3] building sanitized libFuzzer targets: fuzz_eval fuzz_compile fuzz_regexp ==="
cp -f mayhem/fuzz_common_fixed.c fuzz/fuzz_common_mayhem.c

OBJDIR=.obj/asan
CFLAGS="$DEBUG_FLAGS -fsanitize=undefined $UBSAN_RELAX_FLAGS -fno-sanitize-recover=all" \
LDFLAGS="$DEBUG_FLAGS -fsanitize=undefined $UBSAN_RELAX_FLAGS -fno-sanitize-recover=all" \
  make -j"$MAYHEM_JOBS" CONFIG_CLANG=y CONFIG_ASAN=y \
       "$OBJDIR/fuzz_eval.o" "$OBJDIR/fuzz_compile.o" "$OBJDIR/fuzz_common_mayhem.o" \
       libquickjs.fuzz.a fuzz_regexp

# fuzz_regexp never touches the module loader, so `make ... fuzz_regexp` above already
# built+linked it in one step (upstream's own target/recipe, untouched).
[ -x ./fuzz_regexp ] || { echo "FATAL: ./fuzz_regexp not built by 'make fuzz_regexp'" >&2; exit 1; }
# `-ef`: skip the copy when $SRC is already /mayhem (the real container) so `./fuzz_regexp`
# and `/mayhem/fuzz_regexp` are literally the same file -- `cp` errors on a self-copy.
[ ./fuzz_regexp -ef /mayhem/fuzz_regexp ] || cp -f ./fuzz_regexp "/mayhem/fuzz_regexp"
echo "installed /mayhem/fuzz_regexp"

# fuzz_eval / fuzz_compile: link manually against fuzz_common_mayhem.o instead of the
# `fuzz_eval:`/`fuzz_compile:` Makefile targets (which pull in the broken fuzz_common.o).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize-recover=all $UBSAN_RELAX_FLAGS \
    "$OBJDIR/fuzz_eval.o" "$OBJDIR/fuzz_common_mayhem.o" libquickjs.fuzz.a \
    -o /mayhem/fuzz_eval $LIB_FUZZING_ENGINE
echo "installed /mayhem/fuzz_eval"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize-recover=all $UBSAN_RELAX_FLAGS \
    "$OBJDIR/fuzz_compile.o" "$OBJDIR/fuzz_common_mayhem.o" libquickjs.fuzz.a \
    -o /mayhem/fuzz_compile $LIB_FUZZING_ENGINE
echo "installed /mayhem/fuzz_compile"

# ── 3) Standalone (non-fuzzer) reproducers: relink the SAME sanitized objects against
#      LLVM's run-once driver ($STANDALONE_FUZZ_MAIN) instead of the libFuzzer engine.
#      One input file, runs LLVMFuzzerTestOneInput once, crashes naturally — no
#      libFuzzer runtime. C harnesses, so $STANDALONE_FUZZ_MAIN compiles with $CC. ──
echo "=== [3/3] building standalone reproducers ==="
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize-recover=all $UBSAN_RELAX_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize-recover=all $UBSAN_RELAX_FLAGS \
    "$OBJDIR/fuzz_eval.o" "$OBJDIR/fuzz_common_mayhem.o" libquickjs.fuzz.a /tmp/standalone_main.o \
    -o /mayhem/fuzz_eval-standalone -lm -lpthread -ldl

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize-recover=all $UBSAN_RELAX_FLAGS \
    "$OBJDIR/fuzz_compile.o" "$OBJDIR/fuzz_common_mayhem.o" libquickjs.fuzz.a /tmp/standalone_main.o \
    -o /mayhem/fuzz_compile-standalone -lm -lpthread -ldl

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize-recover=all $UBSAN_RELAX_FLAGS \
    "$OBJDIR/fuzz_regexp.o" "$OBJDIR/libregexp.fuzz.o" "$OBJDIR/cutils.fuzz.o" "$OBJDIR/libunicode.fuzz.o" \
    /tmp/standalone_main.o -o /mayhem/fuzz_regexp-standalone -lm

for f in fuzz_eval-standalone fuzz_compile-standalone fuzz_regexp-standalone; do
  [ -x "/mayhem/$f" ] || { echo "FATAL: /mayhem/$f not built" >&2; exit 1; }
done

# ── Per-target dictionaries (fuzz.dict = collected JS builtin identifiers; upstream's
#    own OSS-Fuzz build.sh ships the SAME dict to both fuzz_eval and fuzz_compile —
#    fuzz_regexp gets its OWN dict instead: its input is `pattern\0subject`, so the pattern
#    half is regexp SOURCE and regexp-syntax tokens are the right vocabulary; a JS-builtin
#    identifier dict is not, which is why it previously had none at all.
#    Mayhemfiles reference the flattened /mayhem/<target>.dict path. ─────────────────
for target in fuzz_eval fuzz_compile fuzz_regexp; do
  d="$SRC/mayhem/$target/$target.dict"
  [ -f "$d" ] || { echo "FATAL: missing dictionary $d (referenced by mayhem/Mayhemfile_$target)" >&2; exit 1; }
  cp -f "$d" "/mayhem/$target.dict"
  echo "installed /mayhem/$target.dict"
done

echo "build.sh complete:"
ls -la /mayhem/fuzz_eval /mayhem/fuzz_compile /mayhem/fuzz_regexp \
       /mayhem/fuzz_eval-standalone /mayhem/fuzz_compile-standalone /mayhem/fuzz_regexp-standalone \
       /mayhem/fuzz_eval.dict /mayhem/fuzz_compile.dict ./qjs
