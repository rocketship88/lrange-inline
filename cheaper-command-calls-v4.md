# Cheaper command calls for built-in leaf commands

Oct 9, 2026 · @ET

A call to a built-in math function such as abs, which is a plain C command in `::tcl::mathfunc` (but not a user-defined proc in that namespace), costs about 861 instructions in Tcl trunk, and roughly 320 of those are call machinery that does nothing for a command that cannot recurse. This note proposes a guarded fast path for audited leaf commands, and a dedicated math-function instruction as a later step.

A leaf command is a C command that never runs Tcl code and never needs to pause, such as a math function.

## Measurements

One call to abs through invokeStk takes 861 instructions, of which about 320 are the non-recursive call machinery and only 78 are the function's own work. These are exact instruction counts from callgrind (stock Tcl trunk, TAL sequence `push tcl::mathfunc::abs; load x; invokeStk 2`, x=7). Each figure is the difference between a 100,000-iteration run and a 0-iteration run, divided by 100,000, minus an empty loop. They are counts, not times.

| Part | Instructions | Share |
| --- | --- | --- |
| Bytecode executor (TEBCresume): the three instructions and re-entry | 277 | 32% |
| Call machinery (EvalObjvCore 114, TclNRRunCallbacks 88, TclNREvalObjv 57, NRCommand 25, TclInterpReady 23, Dispatch 8, TclResetRewriteEnsemble 7) | 322 | 37% |
| Command lookup (cached) | 31 | 4% |
| The function itself (ExprAbsFunc, Tcl\_GetNumberFromObj) | 78 | 9% |
| Result handling | 59 | 7% |
| Object allocation and freeing | 76 | 9% |
| Other | 18 | 2% |

The machinery rows are identical for stock lrange called with variable indices (EvalObjvCore 114, TclNRRunCallbacks 88, TclNREvalObjv 57), so this is a fixed cost per command call whatever the command. Calls to small commands pay it proportionally the most. The tryCvtToNumeric that expr adds costs a further 214 at x=7, and is not part of the proposal below.

## Proposal: a direct call for audited leaf commands

Today the INST\_INVOKE\_STK handler saves its state, returns to the trampoline through TclNREvalObjv, and is re-entered through a callback when the command finishes. For a command that never evaluates scripts and never needs to be paused, none of that is needed.

The proposal is that an audited command carries a "safe leaf" flag, and the invokeStk handler calls its C function directly when a short list of guards passes. When any guard fails, that execution takes the existing route unchanged, so behaviour stays identical. The decision is made fresh on every execution, because a trace or a redefinition can appear between two runs of the same compiled code.

This changes no user-visible behaviour, only the cost of the call, so it can be reviewed as a performance change. A first version would flag only a few commands with the same cost profile (abs, int, double) so the guards and tests can be reviewed on a small surface.

## Guards and qualifying commands

A flagged command is called directly only if every check below passes on this execution. Each would be a small named inline function, ordered cheapest and most likely to fail first, so the list is easy to read, test and later make conditional.

1. The command is flagged safe leaf (one bit test on the command record's existing flags field) and has no non-recursive implementation of its own (`nreProc2` unset). Every invokeStk call pays this test, and most go to procs that will fail it, so it comes first and must cost almost nothing.
2. The command has no execution traces (`CMD_HAS_EXEC_TRACES`).
3. No interpreter-wide trace is active (`iPtr->tracePtr`).
4. The command resolved from the cached lookup is not dead, deleted, renamed or redefined.
5. Limits are not exceeded, and no async event or cancellation is pending.
6. The interpreter is ready (`TclInterpReady`).
7. Debug-frame mode is off (`INTERP_DEBUG_FRAME`).

After the call the fast path must do what the normal route does: count the command, run the async, cancellation and limit checks, push an OK result, and send any other return code to the existing exception handling.

The flag lives on the command record, not on the name. A proc defined in `::tcl::mathfunc`, or a proc that replaces a built-in such as abs, is a different command record without the flag, so guards 3 and 4 send it down the existing route with no special case.

Reading the flag needs the command record, so the handler must resolve the command first. To keep non-flagged calls (procs, mostly) from paying for that lookup twice, the handler would pass the command it already found to TclNREvalObjv, whose last argument accepts a pre-resolved command. That equivalence, including namespace resolution, has to be verified and tested. The cost to a non-flagged call, before and after, is the first number the prototype should report. An alternative is for the compiler to emit a distinct instruction only for audited command names, which costs ordinary calls nothing but needs the list of names in the compiler.

A leaf command does its work and returns without running Tcl code or calling the evaluator. Candidates are the math functions, llength, lindex on a plain list, lrange and string length. Procs, eval, uplevel, if, catch, source, foreach, lmap, lsort with a command, ensembles, aliases and imports stay on the existing route. A leaf can still run script code indirectly, for example through a variable write trace, so the audit must consider that case, and the trace guards fall back when one exists.

## Alternative: choose the instruction at compile time

Instead of testing a flag in invokeStk at run time, the compiler could emit a distinct instruction, for example "invokeLeaf", when the command name it is compiling is on the audited list. Ordinary calls would then use plain invokeStk exactly as today and pay nothing at all, so procs are not affected in any way.

What it costs:

- The compiler needs the list of audited names, and the assembler and disassembler need the new instruction.
- The compiler sees only a name. It cannot know that the name will still refer to the built-in at run time, because the command can be redefined, renamed or shadowed in another namespace after compilation. So the run-time guards (redefinition, traces, limits) stay on the new instruction. What is saved is only the flag test on other calls.
- For math functions expr always compiles the fully qualified name `tcl::mathfunc::NAME`, so there is no namespace ambiguity there, which makes them the natural first case. For ordinary commands such as lrange, resolution is relative to the current namespace and is less certain.
- It touches more files, so the review surface is larger than the flag version.

The flag version is simpler and covers any call path, including calls built at run time. The compile-time version removes the last cost to non-audited calls. The prototype should measure that cost first, which says whether the extra work is justified. The math-function instruction described below is the compile-time approach applied to one family.

## Status and prototype results

A working prototype of the flag version exists. It began with `abs`, `int` and `double` (about 25% fewer instructions per call) and now covers all 58 built-in math functions, described below; calls to every other command cost the same number of instructions as before. It lives in a separate copy of Tcl trunk (base commit 78dedf7), not in the `lrange-inline` branch, and it has been checked only by its author and Claude.

Done so far: this write-up and design; the prototype (about 150 added lines in `tclBasic.c`, `tclExecute.c` and `tclInt.h`, plus about 100 lines of test-only commands in `tclTest.c`) with all 58 `::tcl::mathfunc` functions flagged; a behaviour comparison against stock Tcl; the official test suite; instruction and wall-clock measurements; and a test file, `tests/fastleaf.test`, with a mutation check of its guards (see Tests). Not done: review by anyone else, other platforms, any audit of further commands, the compile-time alternative, and the math-function instruction.

| Call in a proc loop | Stock (instructions) | Prototype (instructions) | Change |
| --- | --- | --- | --- |
| `expr {abs($x)}` | 1069 | 798 | −25% |
| `expr {int($x)}` | 1073 | 801 | −25% |
| `expr {double($x)}` | 1030 | 758 | −26% |
| `expr {floor($x)}` (not flagged) | 2190 | 2189 | 0% |
| `lsearch {a b c} a` (not flagged) | 1123 | 1120 | 0% |
| user proc call | 1846 | 1841 | 0% |

These are exact callgrind counts per call, loop overhead subtracted, measured with `expr` inside a proc loop. They include the small amount of work around the call, so they are not directly comparable with the 861 above, which counts only the TAL call sequence.

In wall-clock time, `abs` and `int` fall from about 144 ns to about 121 ns per iteration. Unflagged calls look about 1–2% slower in wall time (`floor` about 149–157 ns before, 153–158 ns after; a proc call about 224 ns before, 228 ns after), although their instruction counts are unchanged. The cause is not established. A code-layout effect in the very large executor function is the likely one: the empty loop alone moved by about 4% between builds with no relevant change. A control build with the fast path present but no command flagged would settle it.

Correctness checks:

- The official test suite gives the same result as the unmodified tree: 509262 tests, 502746 passed, 6508 skipped, 8 failed, all in `httpProxy.test`.
- A 453-line behaviour transcript is identical between stock and prototype. It covers redefining, renaming and deleting the commands, execution traces, command and time limits, cancel, recursion limits, namespaces, import and alias, safe interps with hidden commands, coroutines, argument expansion, and the full error details (`-errorinfo`, `-errorline`, `-errorstack`).
- The transcript runs clean under valgrind memcheck.
- Callgrind confirms the fast path is taken for a plain call and declined when an execution trace is present or the command has been redefined.

The tests found one real difference. The executor runs its async, cancel and limit check right after every command that goes through the normal route, and the first version of the fast path skipped it, so command limits stopped at a different iteration and an expired time limit could be missed. The fast path now restarts that counter, and the figures above include the cost. It also means the fast path repeats the same checks the normal route makes twice. Removing the duplicate would save more instructions but would change when limits fire, so it is left as a decision for the reviewers.

**Extended to all 58 built-in math functions.** Reading every function in the `::tcl::mathfunc` table and its helpers found no script evaluation and no NR callbacks, so the prototype now flags all 58 when they are registered. The conversions they use on their arguments are the same ones the compiled `add` and `lt` instructions already run in-line, so this adds no new kind of exposure.

- A comparison against stock Tcl over every function and 47,734 argument lists (0–3 arguments, called directly and inside `expr`, comparing the return code, result and full error details) is identical.
- A scenario comparison for 30 functions (execution traces, redefine, rename, delete, alias, coroutine, tailcall, command and time limits, cancel, recursion limit) is identical.
- The official test suite again gives the unmodified result (509262 tests, 8 failures, all in `httpProxy.test`), and both comparison runs are clean under valgrind memcheck.
- Callgrind confirms 580 of 580 test calls took the fast path.
- Instructions per call fall 20–30% for every function measured: `sin` 1120 to 848, `pow` 1269 to 996, `isnan` 910 to 637, `max` 1369 to 1096, `lgamma` 1322 to 1050.
- Wall-clock time per loop iteration falls 12–21% (median of 7 interleaved rounds): `sin` 154 to 133 ns, `pow` 186 to 151 ns, `exp` 164 to 130 ns, `isnan` 131 to 107 ns, `lgamma` 192 to 160 ns.

The heavier the function's own work, the smaller the share saved. The unflagged-command slowdown of 0.6–2.5% reported above was measured on the three-function build and has not been re-measured on this one.

## Tests

No patch is offered without a test for each guard and for the error path.

- A trace added, then removed, between two calls of the same compiled proc.
- An execution trace on the command itself.
- Redefining, renaming and deleting a flagged command between calls.
- A limit or cancellation set mid-run.
- Non-numeric and wrong-count arguments, with messages identical to the normal route, inside and outside catch.
- `info frame` and error traces from inside a fast-pathed call.
- The full existing test suite before and after, plus callgrind instruction counts per command before and after, including a check that the guard function was inlined.

The list above was the plan. It is now implemented as `tests/fastleaf.test` (96 tests, included in the patch).

**How it works.** The interpreter's flags word gets one new bit, `FAST_LEAF_OFF` (0x2000). While it is set, `TclFastLeafInvoke` declines every call, so flagged commands take the normal route. Nothing in the core sets the bit. The only way to set it is a test-only command, `testfastleaf disable ?boolean? ?child?`, registered in `tclTest.c`, so it exists in the `tcltest` binary that `make test` builds and not in the installed `tclsh`. No `interp` option or public API is added; whether to offer one is a decision for the maintainers.

**Two passes.** The file runs the same scenarios twice in one process: pass 1 with the bit set (the stock route inside the same binary) and pass 2 with it clear. Each outcome is saved: return code, result, `-errorcode`, `-errorinfo`, `-errorline`, `-errorstack` and side effects. One test per scenario then checks that the two passes are identical.

**Proof that the fast route is taken.** A comparison means nothing if both passes secretly use the same route. A flagged probe command, `testfastleafprobe`, returns the number of NR callback records queued while it runs. The normal route queues two more than the direct route (6 against 4), and four tests check that difference, that an execution trace or a redefinition removes it, and that the bit is off by default.

**What is covered.** All 58 functions with many argument lists, called by name and inside `expr`; per-function scenarios (execution traces, a trace that errors, rename, redefine, delete, alias, coroutine, tailcall, uplevel, command and time limits, cancel, recursion limit); namespaces, safe interpreters and hidden commands; and a group that uses `srand` and `rand` to show whether a call was wrongly run or wrongly skipped under cancel, command limits, an async handler, a C-level command trace and frame debugging. With the file added, the official suite gives 509358 tests and 8 failures, all in `httpProxy.test`, as for the unmodified tree.

**Mutation check.** To find out whether the tests would notice a mistake, 18 mutants of the build were made. Each removes or weakens one step or guard of `TclFastLeafInvoke` or of its call site; `tcltest` is rebuilt and `fastleaf.test` is run. A mutant is killed if at least one test fails and survives if all pass. The scripts (`mutate.py`, `runmut.sh`) and the results are in `extras/` of the zip. The mutants were chosen by hand, one per guard, so this is a targeted check and not a full mutation analysis.

- Killed (8): not restarting the interrupt counter, ignoring execution traces, ignoring the interpreter-wide trace, skipping the level count, skipping the command count, skipping `TclInterpReady`, skipping the limit check after the call, and ignoring the `FAST_LEAF_OFF` bit.
- Survived (10): ignoring `CMD_DEAD`; a limit already exceeded before the call; the cancel flags; `INTERP_DEBUG_FRAME`; the ensemble-rewrite reset; the async check after the call; the cancel check after the call; the NR-implementation check; deferred callbacks; and the rewind check.

The first round killed 7; the extra scenarios raised it to 8. The survivors look unreachable from a script for the 58 math functions (the NR-implementation check, deferred callbacks, rewind, a dead command) or hidden by another check (a pending cancel or an exceeded limit is noticed before the next call is made, and the async and cancel checks after the call are repeated when the executor resumes, the duplication described above). Debug-frame mode and the ensemble-rewrite reset change nothing a script can see here. That is a reading of the code and not something the tests prove, so the correctness of these ten guards rests on review. They would matter if a command that can reach those states were ever flagged.

## Follow-on and open measurements

A second step would add one new instruction that calls a built-in math function by a one-byte table index. The base commit already uses 211 of the 256 (212 with the lrange branch) one-byte opcodes, so promoting each of the 58 functions to its own opcode is not possible, but a single table-driven opcode costs one value. The expr compiler already knows the function name and argument count where it emits INVOKE\_STK in CompileExprTree, and the existing function implementations already take (clientData, interp, objc, objv) with the stack holding exactly that vector. The same redefinition guard applies. Min and max take variable arguments and would keep using invokeStk. This is an idea only: it is not built or measured, and the quirks (redefinition, traces, limits) are not worked out.

Not yet measured or checked:

- How much of the executor's 277 instructions is re-entry after the call. That needs a line-level profile with debug symbols.
- The cost of the guards themselves, and the size of the saving. Both are estimates until a prototype exists. A reduction from 861 to somewhere around 450 to 550 is a guess.
- Which object is allocated and freed on each call (about 76 instructions).
- Behaviour on platforms other than Linux x86-64, and with the threaded allocator turned off.

A per-command bitmask of which guards apply is a possible later refinement, and is deliberately not part of this proposal.

**Other possible leaf commands** (none audited or flagged). `divmod`, `frexp`, `modf`, `remquo` and `fpclassify` are separate global commands, not math functions: they return two values or a word, so `expr` cannot use them, but they are plain C commands with no compile function and no NR version. `lsearch`, `join`, `split`, `lreverse`, `lrepeat` and `lremove` also have neither. Each would need the same audit as the math functions (no script evaluation, no variable access that can fire a trace, no use of the call frame) and the same tests. Commands that write variables (`scan`, `regexp`), take a script option (`lsort -command`) or are ensembles are not candidates.

## Provenance

This note was written by Claude, an AI, at Eric Taylor's request, from source reading and measurements Claude ran in its own build environment. Eric has not independently verified the measurements or the reading of the source. The call-path description comes from tclExecute.c (INST\_INVOKE\_STK, TEBC\_YIELD), tclBasic.c (TclNREvalObjv, EvalObjvCore, Dispatch, NRCommand) and tclInt.h, in a trunk checkout. Please treat anything here as unconfirmed until it has been checked by someone who knows the code.

The earlier lrange-inline branch (Fossil check-in 5c9d6b18) was produced the same way: written by Claude, reviewed by Eric, with the full Tcl test suite run on it by Eric.

The prototype in `fastleaf-v4.zip`, `tests/fastleaf.test` and the mutation check were also written and run by Claude and have not been independently reviewed. Eric does not claim to understand all of it, and asks the core team to review it closely.
