/* mayhem/fuzz_common_fixed.c — drop-in replacement for upstream's fuzz/fuzz_common.c.
 *
 * WHY THIS FILE EXISTS: upstream's fuzz/fuzz_common.c does not build against upstream's
 * CURRENT quickjs.h. It calls the 3-argument `JS_SetModuleLoaderFunc(rt, NULL,
 * js_module_loader, NULL)`, but `js_module_loader` (quickjs-libc.h) was changed to the
 * 4-argument `JSModuleLoaderFunc2` signature (it now takes the import-attributes JSValue,
 * for `import ... with { type: "json" }` support) and is wired everywhere else in the tree
 * -- including quickjs-libc.c's own `js_std_init_handlers` -- via `JS_SetModuleLoaderFunc2`
 * paired with `js_module_check_attributes`. fuzz/fuzz_common.c was simply never updated
 * after that API change landed, so `CONFIG_CLANG=y make libfuzzer` fails outright with
 * "incompatible function pointer types" on a clean upstream checkout (verified independent
 * of this integration). Upstream files are off-limits (additive-only invariant), so this is
 * a same-behavior copy under mayhem/ with ONLY that one call site corrected; build.sh stages
 * it into fuzz/ under a NON-colliding name (fuzz_common_mayhem.c) so it compiles via
 * upstream's own `$(OBJDIR)/fuzz_%.o: fuzz/fuzz_%.c` pattern rule with upstream's own flags,
 * without ever overwriting the tracked fuzz_common.c.
 *
 * Everything below this comment is byte-for-byte upstream's fuzz/fuzz_common.c except the
 * one JS_SetModuleLoaderFunc -> JS_SetModuleLoaderFunc2 call in test_one_input_init().
 */

/* Copyright 2020 Google Inc.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#include <string.h>

#include "fuzz/fuzz_common.h"

// handle timeouts from infinite loops
static int interrupt_handler(JSRuntime *rt, void *opaque)
{
    nbinterrupts++;
    return (nbinterrupts > 100);
}

void reset_nbinterrupts() {
    nbinterrupts = 0;
}

void test_one_input_init(JSRuntime *rt, JSContext *ctx) {
    // 64 Mo
    JS_SetMemoryLimit(rt, 0x4000000);
    // 64 Kb
    JS_SetMaxStackSize(rt, 0x10000);

    // FIXED: js_module_loader is JSModuleLoaderFunc2 (takes import attributes) in the
    // current tree -- JS_SetModuleLoaderFunc2 + js_module_check_attributes is what
    // quickjs-libc.c's own js_std_init_handlers() pairs it with.
    JS_SetModuleLoaderFunc2(rt, NULL, js_module_loader, js_module_check_attributes, NULL);
    JS_SetInterruptHandler(JS_GetRuntime(ctx), interrupt_handler, NULL);
    js_std_add_helpers(ctx, 0, NULL);

    // Load os and std
    js_std_init_handlers(rt);
    js_init_module_std(ctx, "std");
    js_init_module_os(ctx, "os");
    const char *str = "import * as std from 'std';\n"
                "import * as os from 'os';\n"
                "globalThis.std = std;\n"
                "globalThis.os = os;\n";
    JSValue std_val = JS_Eval(ctx, str, strlen(str), "<input>", JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (!JS_IsException(std_val)) {
        js_module_set_import_meta(ctx, std_val, 1, 1);
        std_val = JS_EvalFunction(ctx, std_val);
    } else {
        js_std_dump_error(ctx);
    }
    std_val = js_std_await(ctx, std_val);
    JS_FreeValue(ctx, std_val);
}
