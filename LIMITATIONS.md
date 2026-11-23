# Limitations

Known gaps, by area.

## Platform

- One window per process. The SDL3 platform reads every window's events and
  quits SDL when it closes.
- Popups stay inside the window, no OS popup windows.
- File dialogs on Linux need an XDG portal or zenity, else they answer as
  cancelled.
- A hidden window still draws the frames asked for, such as animations.
- Window icons take one image, no extra sizes.
- No system tray icon. A window hidden with `setVisible(false)` has no way back
  for the user.

## Rendering

- No Vulkan renderer. Everything above the renderer sees only `FrameMesh`.
- Clean layers are copied into one frame mesh, uploaded whole every frame.
- Glyph quads cost about 350 ns each, most of a changed island's cost.
- Software renderer: one thread, whole frame every time, skips raw views.

## Images

- SDL3_image is only loaded at run time, no configuration links it.
- One texture per image, no atlas, so many images split batches.
- SVGs load at their own size, not the display scale.
- No mipmaps (below half size aliases), no rounded corners.
- Animations show their first frame.
- A scaled sub-image blends in pixels just outside it.

## Text

- Fallback glyphs take the slot font's line height and regular weight.
- Color glyphs: CBDT bitmap (Noto) and COLRv0 (Segoe, Twemoji) fonts. COLRv1
  and SVG fonts draw nothing, sbix (Apple) is untested and not in the system
  list. Color glyphs snap to whole pixels, bitmaps scale up without smoothing.
- Emoji presentation comes from a built-in table, not Unicode data.
- System fonts come from a fixed path list, no fontconfig.
- Input methods: the platform draws the candidate list. A press in a text
  area waits for the commit. Lists show no composition.
- X11 without an input method: dead key accents do not show.
- `ui.withStyle` edits do not reach island labels, which resolve their style
  at layout.

## Accessibility

- A label next to a control does not name it, set `accessName` on uncaptioned
  controls.
- Text fields have no character bounds, screen readers cannot move the caret.
- Dock panes are not named by their tabs.
- Table cells are not exposed as cells.
- Context menus do not open from a screen reader.
- No live regions.
- Island text boxes take no `setValue`.
- Only the Linux adapter has been run (AT-SPI). Windows and macOS follow
  accesskit-c's SDL example.

## Widgets

- Lists, trees, tables: type-ahead matches the text start only.
- Trees: no drag and drop.
- Tables need a bounded height.
- Virtual list: a width or theme change measures rows again, from the one at
  the top of the view.
- Text areas: plain text, no colors, tabs become spaces. Every edit writes the
  whole text to the signal. Relayout shapes every line, fine for thousands of
  lines, not huge files.
- Sliders: horizontal only, no tick marks.
- Tab bars: no tab dragging.
- Spin boxes: plain decimals only, no units, separators or hex.
- Tooltips: text only.
- Popups: a plain column stretches to the window width, give it a width.
  Menus size to their items.
- Menus: mnemonics show only after a menu opened from the keyboard (Alt alone
  is not seen without key releases). A press on an island menu button cannot
  be dragged onto an item.
- Combo boxes: natural width measures the first 1000 labels, give longer lists
  a width. Filtering is substring in item order, no ranking. Island combo
  boxes are not editable, and a press on them cannot be dragged onto an item.

## Dock

- Floating windows stay inside the main window.
- Pressing floating content does not raise it, only its tab bar or border.
- No keyboard way to move panes.
- Losing window focus mid-drag drops the tab.
