# debugger

Debugger-shaped dentrite example: retained breakpoints and registers panels,
disassembly, memory and console islands, a raw GL cube and a fake debug target
on its own thread, in a dock view with tabs and splitters.

## Build and run

From this directory:

```sh
dub build
./bin/dentrite-debugger    # loads ../../fonts/ and themes/ relative to the working directory
dub test                   # unittests of the app modules
```

## Using it

| Key | Does |
|---|---|
| F5 | run or pause the target |
| F10 | step once while paused |
| F9 | toggle a breakpoint on the selected disassembly row |
| Tab, Shift+Tab | move focus, rings show only after Tab |
| arrows, Page Up/Down | move the selection in a focused island |
| Ctrl+R | reload `themes/dark.theme`, a bad file keeps the old theme |
| Alt+F, Alt+D, Alt+V | open a menu, then arrows, Enter and letters |
| Shift+F10, Menu | context menu of the focused node |
| Ctrl+Q | quit |
| F12 | write a screenshot to the working directory |

Click the disassembly gutter to toggle a breakpoint. Selecting a breakpoint row
jumps the disassembly to it. Right-click a breakpoint row to disable or remove
it, or press Delete after clicking it. The breakpoint filter suggests source
files as you type, and the box next to it shows all, enabled or disabled
breakpoints. Hover the tool bar buttons for their shortcuts. Drag splitters,
click tabs. Drag a tab onto a drop button to dock it there, onto a tab bar to
move it among those tabs, or anywhere else to float it. Move a floating window
by its tab bar, resize it by its border. Escape cancels a drag. The layout is
written to `layout.json` on quit and read at start, View, Reset layout brings
back the default.

Options: `--scale 1.5` forces a scale, `--size 1280x800`, `--paused`,
`--no-target`, `--no-vsync`, `--no-cache` (record every layer every frame, to
compare), `--renderer software` (CPU rasterizer, the viewport tab stays empty),
`--layout FILE` (layout file, none by default with `--shot` or `--duration`).
For headless checks:

```sh
xvfb-run -a ./bin/dentrite-debugger --paused --duration 3     # frames drawn by the real loop
xvfb-run -a ./bin/dentrite-debugger --shot out.png --frames 30 \
    --script "click:200,102; type:main; wait:3; key:f5"       # prints each step's time
```

Script steps: `click:X,Y`, `dclick:X,Y`, `rclick:X,Y`, `move:X,Y`,
`down:X,Y`, `up:X,Y`, `drag:X0,Y0,X1,Y1`, `wheel:X,Y,DY`, `type:TEXT`, `key:SHORTCUT` (such as
`key:Alt+D`), `wait:FRAMES`. Coordinates are logical pixels. Each step prints
its time, split into input and effects, and layout. The `--frames` frames
before the shot print their mean timings.

## What's where

| Path | What |
|---|---|
| `source/app.d` | Window setup, dock layout and its file, headless options. |
| `source/debugger/` | Fake program and session, target thread, commands, menus, retained panels, island views, GL cube. |
| `themes/dark.theme` | Every color and size the app uses. |

## Measured

Headless, Mesa llvmpipe (CPU GL), 1280x800 at 100%. Rendering on a GPU will be
cheaper, the other numbers are CPU work and will not change much.

Frames are means of 100 (`--frames 100`) from `dub build`. Tess is the
tessellation of the layers recorded in them.

| Frame | Cached | `--no-cache` |
|---|---|---|
| Running, 14 breakpoints | 2.2 ms, tess 0.33, 13 of 27 layers | 2.45 ms, tess 0.51 |
| Running, 1014 breakpoints, all hit counts live | 2.6 ms, tess 0.37, 4 layers | 2.8 to 2.9 ms, tess 0.55 |
| Running at 200% | 2.5 ms, tess 0.36 | 2.8 to 2.9 ms, tess 0.59 |
| Paused, only the status bar changes | 1.1 ms, tess 0.06, 1 layer | 1.7 ms, tess 0.46 |
| Wheel scroll step, 1014 rows, paused | 2.4 to 3.0 ms | 2.6 to 3.4 ms |

What still records while running is content that changed: the disassembly or
console island after its pass (0.12 to 0.14 ms of tessellation), the registers
(0.06), the tool and status bars (0.06), and each row whose hit count changed
(0.008). Without the cache, every layer is tessellated every frame (0.5 ms).
Cached and uncached screenshots are identical, at 100% and 150%.

GL keeps a vertex and index buffer per layer, uploaded again only when the layer
is recorded: about 205 KB here, as much as the frame's vertices. Buffers of
layers not drawn for 120 frames, such as a closed menu's, are freed then, so
switching tabs and opening menus peaks at about 470 KB for 2 s.

| Case | Cost |
|---|---|
| Paused, nothing focused | 3 frames in 3 s (first frame, expose, exit) |
| Running, no vsync | 120 frames/s, the cap. Hits arrive every 1 ms |
| Island pass, disassembly or console | 0.2 to 0.5 ms |
| Add 500 breakpoints, through the next frame | 3.1 to 3.5 ms, of which effects and layout 0.4 to 0.5 |
| Filter 1514 rows to none | 4.6 to 5.6 ms, of which effects 2.3 to 3.1 |
| Clear the filter, 1514 rows back | 2.8 to 3.0 ms, of which effects and layout 0.26 to 0.30 |
| Wheel scroll: inside the overscan, rebinding some rows, jumping far | layout 0, 0.13 to 0.16, 0.35 to 0.47 ms |

The step times are mostly the frame itself. With keyed rows (`keyedColumn`), adding 500
rows took 9.9 and 12.6 ms and clearing the filter 8.7 to 11 ms, at the 8 ms line
of report section 11.4. The breakpoints panel now uses `virtualList`: about 20
pooled rows rebind to whatever is in view, so structural change costs well
under 1 ms. The filter cost is `matches` formatting each location, not the list.

Renderers, running, means of 100 frames. Render is the renderer's share of the
frame, the rest is the same for both:

| Build | GL 100% | GL 150% | Software 100% | Software 150% |
|---|---|---|---|---|
| `dub build` (dmd, debug) | 1.04 ms | 1.20 ms | 12.0 ms | 20.7 ms |
| `--compiler=ldc2 -b release` | 1.02 ms | 1.16 ms | 3.0 ms | 5.4 ms |

The software renderer draws every pixel of every frame, on one thread. Released,
it holds the 120 frames/s cap like GL does. Its pixels match GL's within one
level per channel, and about 2.5% of them differ at all.
