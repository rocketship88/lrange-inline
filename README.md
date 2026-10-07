# lrange-inline

An experiment: compile `[lrange]` inline when an index is **not** a literal.

Tcl already compiles `lrange $l 1 3` to a single instruction (`listRangeImm`).
But `lrange $l $i $j`, `lrange $l $i end` and `lrange $l 1 end-$n` fall back to
a full command call (`invokeStk`). This change adds a new instruction,
`listRange`, that takes exactly three values from the stack (the list and both
indices), and makes the compiler use it in those cases.

**The code and the tests were written by Claude (Anthropic's AI assistant),
working in a Linux sandbox with access to the GitHub mirror of the Tcl source.
It was reviewed, merged into a local tree, built and tested by
[rocketship88](https://github.com/rocketship88) on two machines.** This is an
experiment and a data point, not a proposal that has been accepted by anyone.

## Where it came from

A tool that scans every proc in every package of a Magicsplat install was
extended to count which commands are called through the command table
(`invokeStk`) instead of being compiled inline. Most of what came up (`format`,
`regsub`, `lsort`, ...) does real work per call, so call overhead is a small
part of the cost. `lrange` with a non-literal index stood out as cheap enough
for the call overhead to matter. I did not measure how much real programs
would gain, only the cost of the call itself.

## The commits

1. **Base**: the 8 original files, exactly as in Tcl `main`, commit `78dedf7`
   (2026-10-05, from the `github.com/tcltk/tcl` mirror).
2. **Add listRange instruction**: the same 8 files after the change. The
   commit page shows the whole change as a side-by-side diff.

## What changed

66 lines of C added and 16 removed; 161 lines of tests added.

| File | Added | Removed | What |
|---|---|---|---|
| `generic/tclCompile.h` | 1 | 0 | new opcode `INST_LIST_RANGE`, at the end of the list so no existing opcode number changes |
| `generic/tclCompile.c` | 7 | 0 | instruction table entry: one byte, no operands, stack effect -2 |
| `generic/tclExecute.c` | 34 | 0 | the instruction |
| `generic/tclCompCmdsGR.c` | 23 | 16 | `TclCompileLrangeCmd` emits `listRange` when an index is not a literal |
| `generic/tclAssembly.c` | 1 | 0 | `tcl::unsupported::assemble` can use `listRange` |
| `tests/lrange.test` | 85 | 0 | `lrange-6.1` .. `6.14` |
| `tests/compile.test` | 38 | 0 | `compile-22.1` .. `22.5` |
| `tests/assemble.test` | 38 | 0 | `assemble-7.47` .. `7.50` |

Nothing outside `generic/` and `tests/` is touched.

## How it works

The instruction does what `Tcl_LrangeObjCmd` does, in the same order: check
that the list is a list, convert the first index, convert the last index, take
the range. So error messages and the order in which arguments are checked are
the same as for the command. When both indices are literals that
`listRangeImm` can encode, nothing changes. Otherwise the compiler pushes the
list, first and last, and emits `listRange`.

Before:

```
push "lrange"
loadScalar args
push 1
loadScalar e
invokeStk 4
```

After:

```
loadScalar args
push 1
loadScalar e
listRange
```

(Depending on where the command sits, the compiler may also emit a
`startCommand` in front, as it does for other inlined commands. That is what
makes a later redefinition of `lrange` take effect; `lrange-6.12` covers it.)

## Tests

- Full suite: 509,285 tests, 23 more than before. The same 8 fail before and
  after (`httpProxy.test`, which needs network access).
- The new tests that look for the new instruction fail on an unmodified build
  (`compile-22.1`, `22.2`, `22.4`, `22.5` and `assemble-7.47` .. `7.50`). The
  behaviour tests (`lrange-6.*` and others) pass on both builds.
- `lrange-6.13` compares the compiled form against the command called through
  a variable, for 6 lists and 20 index forms each way (including invalid
  ones), and expects no difference at all, error messages included.
- Also run in a sandbox: AddressSanitizer plus UBSan, Tcl's own memory-debug
  build (`--enable-symbols=mem`) and the `TCL_COMPILE_DEBUG` build
  (`--enable-symbols=all`, which checks the stack depth after every
  instruction). No problems found. The one test that failed under
  AddressSanitizer (`cmdIL-5.7`) limits address space and cannot work under it.
- `disassemble` and `getbytecode` show the new instruction.

## Timing

Nanoseconds per call, 10-element list, best of 7 runs, before -> after, from
`bench.tcl` in this repo. Machines 1 and 2 are release builds on two Linux
machines. The third column is Claude's sandbox, a small shared VM that is
noisier (repeat runs varied 10-20%).

| | machine 1 | machine 2 | sandbox |
|---|---|---|---|
| `lrange $l $i $j` | 193 -> 126 | 117 -> 72 | 152 -> 98 |
| `lrange $l $i end` | 232 -> 165 | 130 -> 93 | 172 -> 123 |
| `lrange $l 1 end-$n` | 368 -> 291 | 200 -> 161 | 270 -> 212 |
| `lrange $l 1 3` (literal) | 38 -> 39 | 24 -> 23 | 32 -> 34 |

- Non-literal indices: about 20-40% faster. `end-$n` gains least, because the
  string `end-N` is still built and parsed on every call.
- The literal case compiles to identical bytecode in both builds. Its small
  difference changes direction between machines, so it looks like build-layout
  noise in the interpreter loop, not a cost of the change. That is a guess; I
  did not look at the machine code.
- `bench.tcl` has a control line (`$c $l $i $j`) that calls `lrange` through a
  variable. It always takes the ordinary command path and should be the same
  in both builds. It was, on all machines.

## Try it

You need a Tcl source tree at commit `78dedf7` (or close to it).

1. Compare your tree with the first commit here. Any difference shows where
   your tree has moved on. (A folder compare tool is the easiest way.)
2. Copy the 8 files from the second commit over your tree.
3. Build and test, from the `unix` directory of the Tcl tree:

```
./configure && make
make test-tcl TESTFLAGS="-file 'lrange.test compile.test assemble.test'"
```

4. Benchmark, with an unmodified build and a modified one:

```
./tclsh bench.tcl 2000000
```

(`LD_LIBRARY_PATH` and `TCL_LIBRARY` need to point at the build, as usual for a
tree that has not been installed.)

## Limits

- Tested on Linux only. Not built on Windows or macOS, so MSVC has not seen it.
- No integer fast path for `end-$n`. The compiler cannot know `$n` is an
  integer, so a safe version needs a run-time check and a fallback. That would
  be a bigger and riskier change.
- `listRangeImm` is not in the assembler's instruction table, and I did not add
  it; that is outside this change.
- Micro-benchmarks only. I did not measure real programs.

## License

The changed files are part of Tcl and keep Tcl's license. See `license.terms`.
