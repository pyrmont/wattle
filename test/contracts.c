/* The contract driver: one executable over every C contract in `test/`.
 *
 * ## Why one
 *
 * These were fifty-nine separate executables. Phase 10 Part 11 measured what
 * that cost, because a `zig build test` is what the acceptance matrix runs
 * nine times and what the mutation sweep runs for every mutant that escalates
 * to its last judge:
 *
 *     library only                    15.5s     877 MB of cache
 *     library + 59 contracts          44.3s     4.4 GB
 *     everything                      51.7s     4.7 GB
 *
 * Of the twenty-nine seconds the contracts add, compiling all fifty-eight
 * translation units is six. The rest is fifty-nine links against
 * `libjanet.a`, at half a second each, to run about two seconds of assertions.
 * Linking once instead is the whole of this file.
 *
 * ## What did not change
 *
 * The files. A contract is a subject, and fifty-eight subjects stay
 * fifty-eight files with fifty-eight header comments explaining what each one
 * is for and why the Janet suites cannot reach it. A translation unit is free;
 * an executable is not. The three `pp` layers were the first to be folded this
 * way, in the same increment and for the same reason.
 *
 * Each contract still runs its own `janet_init`/`janet_deinit` pair, exactly
 * as it did when it was a `main`, so none of them inherits another's heap.
 * They run in the order `build.zig` declares them.
 *
 * ## Isolation, and why losing it costs nothing here
 *
 * A failing assertion aborts the process and takes the remaining contracts
 * with it, where before it took only its own executable. That is a real
 * difference and a cheap one: `assert` names the file it fired in, which is
 * the contract, and a build that is failing gets fixed before the rest of the
 * run means anything. Nothing in `test/` deliberately ends its own process --
 * the `_exit` calls in `os_process.c` and `value_alloc.c` are all in forked
 * children.
 *
 * ## Running one
 *
 * With no arguments every compiled-in contract runs. With one argument only
 * that contract runs, which is what `contract.sh` uses: it compiles this file
 * against the one source it was asked for and defines only that source's
 * `JANET_CONTRACT_*` macro, so the narrow iteration loop still links one
 * contract and nothing else. */

#include <stdio.h>
#include <string.h>

#define CONTRACT(name) void name##_contract(void);
#include "contracts.h"
#undef CONTRACT

typedef struct {
    const char *name;
    void (*run)(void);
} Contract;

static const Contract contracts[] = {
#define CONTRACT(name) { #name, name##_contract },
#include "contracts.h"
#undef CONTRACT
};

static const int contract_count = (int) (sizeof(contracts) / sizeof(contracts[0]));

int main(int argc, char **argv) {
    if (argc > 1) {
        for (int i = 0; i < contract_count; i++) {
            if (!strcmp(contracts[i].name, argv[1])) {
                contracts[i].run();
                return 0;
            }
        }
        fprintf(stderr, "contracts: %s was not compiled into this binary\n", argv[1]);
        return 2;
    }
    for (int i = 0; i < contract_count; i++) contracts[i].run();
    return 0;
}
