# Research

UI architecture study behind dentrite. The report is the product. The library (`../core/`,
`../gl33/`, `../sdl3/`) grew from the prototype of its recommendation.

## What's where

| Path | What |
|---|---|
| `report.html` | The report. Self-contained, opens offline, light and dark follow the system. |
| `examples/` | Compiled D behind every non-trivial snippet in the report, with unittests. |
| `examples/run-tests.sh` | Runs every example's unittests. |
| `examples/panel.ui` | Markup read at compile time by `builders.d` (`-J.`). |
| `examples/light.theme` | Theme read at compile time by `widgets/button.d` (`-J.`). |
| `tools/sync-snippets.pl` | Copies excerpts of `examples/` into `report.html`, or checks they match. |

### Examples

| File | Shows |
|---|---|
| `signals.d` | alien-signals 3.2 port: signals, computeds, effects, owner scopes, cleanup, batching. |
| `layout.d` | Box-constraint layout: Row, Column, Flexible, Padding, caching, relayout boundaries. |
| `immediate.d` | Immediate API with deferred layout, last-frame hit testing, per-ID memory (path A2). Builds again before drawing after input. `Ui.memo` is path D. Widgets as free functions over `Ui`. |
| `widgets/button.d` | Button component in its own module: content slot, themed look, shared click handling. |
| `theme.d` | Theme file loader: palette tokens, a section per style struct and variant, also at compile time. |
| `panel.d` | Breakpoints panel on signals, keyed rows with owner scopes. |
| `panel_ddui.d` | Breakpoints panel on ddui, headless. Needs ddui. |
| `hybrid.d` | Retained shell with a ddui island and a virtualized hex view. Needs ddui. |
| `virtual.d` | Row virtualization, Fenwick prefix sums, scroll anchoring. |
| `dock.d` | Dock tree, drop zones, simplify, JSON save and restore. |
| `undo.d` | Messages as a SumType, commands, undo history. |
| `mailbox.d` | Backend thread to UI thread hand-off. |
| `render.d` | Draw commands, vertex format, feathered anti-aliasing, subpixel bins. |
| `builders.d` | Six tree construction styles, CTFE markup, UDA inspector. |
| `bench.d` | Timings and memory use of paths A1, A2, B, C and D on the breakpoints panel. Needs ddui. |
| `bench-results.txt` | Raw output of the runs report section 11.5 quotes. |

## Build and test

Tested with ldc2 1.40.0. dmd 2.110 also passes.

All examples. `DDUI` points at a ddui checkout and defaults to `../../../ddui`
relative to `examples/`, which is `/workspace/Projects/ddui`:

```sh
cd examples
./run-tests.sh
DDUI=/path/to/ddui ./run-tests.sh
```

One file at a time, from `examples/`:

```sh
ldc2 -unittest -main -run signals.d
ldc2 -unittest -main -run layout.d
ldc2 -unittest -main -run virtual.d
ldc2 -unittest -main -run undo.d
ldc2 -unittest -main -run theme.d
ldc2 -unittest -main -i -I. -run panel.d
ldc2 -unittest -main -i -I. -run dock.d
ldc2 -unittest -main -i -I. -run mailbox.d
ldc2 -unittest -main -i -I. -run render.d
ldc2 -unittest -main -i -I. -run immediate.d
ldc2 -unittest -main -i -I. -J. -run builders.d
ldc2 -unittest -main -i -I. -J. -run widgets/button.d
ldc2 -unittest -main -i -I. -I../../../ddui/source -run panel_ddui.d
ldc2 -unittest -main -i -I. -I../../../ddui/source -run hybrid.d
ldc2 -unittest -main -i -I. -I../../../ddui/source -run bench.d
```

`-i` compiles imported example modules (and ddui) along with the file, so
their unittests run too.

## Benchmark

`bench.d` measures every path at 50, 1000 and 10000 breakpoints, or at the
sizes given as arguments. Each path and size runs in its own process, and
`--DRT-` options are passed on to them. Build it optimized, from `examples/`:

```sh
ldc2 -O3 -release -i -I. -I../../../ddui/source -of=/tmp/bench bench.d
/tmp/bench                                  # timings, all sizes, about 10 s
/tmp/bench 1000 --DRT-gcopt=disable:1       # one size, GC collections off
/tmp/bench mem                              # memory, about 4 s
/tmp/bench mem --DRT-gcopt=gc:precise       # same, precise heap scanning
```

Timings: median and p99 in microseconds, GC KiB allocated per operation.
Memory: live KiB after a full collection for the model, then for the UI after
two frames and again after a mix of operations, garbage KiB per operation,
collections, GC pool peak, resident size before setup and its peak.
`bench-results.txt` holds the runs the report quotes.
Report section 11.5 has the numbers and what they mean.

## Keeping the report in sync

Code blocks in `report.html` with a `data-src` attribute are excerpts of
`examples/`. After changing an example, from `research/`:

```sh
perl tools/sync-snippets.pl report.html          # rewrite the excerpts
perl tools/sync-snippets.pl --check report.html  # exit 1 if any excerpt is stale
```
