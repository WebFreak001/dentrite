# 10. Custom widgets

Most components are builder functions over existing nodes. When none fits,
subclass `Node` (`dentrite.node`). The library's widgets follow one pattern,
and this chapter walks through it with a star rating:

1. A style struct, read from the theme.
2. Free functions to measure and paint, shared by the retained node and the
   island function.
3. The retained node: binding, layout, paint, input, accessibility.
4. A builder, and an island function.

## Style, measure, paint

<!-- src="examples/source/guide/rating.d" from="struct RatingStyle" -->
```d
/// Look of a rating, theme section `[rating]`.
struct RatingStyle
{
    enum section = "rating"; /// theme section

    Color on = Color(0xf2, 0xb9, 0x50, 0xff);    /// stars up to the value
    Color off = Color(0x43, 0x43, 0x4c, 0xff);   /// the rest
    Color hover = Color(0xf7, 0xd3, 0x8c, 0xff); /// stars up to the one under the pointer
    Color focus = Color(0x3b, 0x82, 0xf6, 0xff); /// focus ring
    float star = 16; /// star width and height
    float gap = 4;   /// between stars
}
```

<!-- src="examples/source/guide/rating.d" from="void paintRating(" -->
```d
/// Paints `stars` stars in `r`, filled up to `value`, or up to `hot` in the hover color when it is not 0, with a
/// focus ring when `ring`. Shared by the node and the island function.
void paintRating(ref PaintContext ctx, Rect r, const ref RatingStyle s, int stars, int value, int hot, bool ring)
{
    foreach (int i; 0 .. stars)
    {
        Rect box = Rect(r.x + i * (s.star + s.gap), r.y, s.star, s.star);
        Color c = hot > 0 ? (i < hot ? s.hover : s.off) : (i < value ? s.on : s.off);
        ctx.list.polygon(starPoints(box), c);
    }
    if (ring)
    {
        ctx.list.rect(r.inset(-3), Color.init, 4, s.focus, 1);
    }
}
```

Paint code draws into `ctx.list` in window coordinates. Nodes do not keep
draw lists of their own: a paint records into the layer of the nearest
paint boundary, and unchanged layers are reused.

## The node

<!-- src="examples/source/guide/rating.d" from="final class Rating : Node" -->
```d
/// Retained rating bound to a signal: click a star, or use the arrow keys while focused.
final class Rating : Node
{
    Signal!int value; /// stars given, 0 for none
    int stars;        /// stars shown
    private int shown; /// value last read
    private int hot;   /// star under the pointer, 0 for none

    /// Creates a rating over `value`. The binding effect belongs to the current owner.
    this(Signal!int value, int stars)
    {
        this.value = value;
        this.stars = stars;
        interactive = true;
        focusable = true;
        cursor = CursorShape.pointer;
        effect(() {
            int v = value.get;
            if (v != shown)
            {
                shown = v;
                markNeedsPaint();
            }
        });
    }

    /// Sets the value, kept in range.
    private void choose(int v)
    {
        value.set(clamp(v, 0, stars));
    }

    /// As wide as its stars.
    protected override Size performLayout(Constraints c)
    {
        RatingStyle s = tree.style!RatingStyle();
        return c.constrain(measureRating(s, stars));
    }

    /// Stars for the current state.
    override void paint(ref PaintContext ctx, Point origin)
    {
        RatingStyle s = ctx.style!RatingStyle();
        paintRating(ctx, Rect(origin.x, origin.y, size.w, size.h), s, stars, shown, hot, focusRing);
    }

    /// Hover shows the stars a click would give, a press gives them.
    override bool onPointer(ref const PointerEvent e)
    {
        RatingStyle s = tree.style!RatingStyle();
        int at = starAt(s, e.pos.x - bounds.x, stars);
        switch (e.kind)
        {
        case PointerKind.enter:
        case PointerKind.move:
            if (at != hot)
            {
                hot = at;
                markNeedsPaint();
            }
            return true;
        case PointerKind.leave:
            hot = 0;
            markNeedsPaint();
            return true;
        case PointerKind.down:
            if (e.button != 1)
            {
                return false;
            }
            choose(at == shown ? 0 : at);
            return true;
        default:
            return false;
        }
    }

    /// Left and Right step, Home clears, End gives every star.
    override bool onKey(ref const KeyEvent e)
    {
        switch (e.key)
        {
        case Key.left:
            choose(shown - 1);
            return true;
        case Key.right:
            choose(shown + 1);
            return true;
        case Key.home:
            choose(0);
            return true;
        case Key.end:
            choose(stars);
            return true;
        default:
            return false;
        }
    }

    /// Focus ring changes.
    override void onFocus(bool gained)
    {
        markNeedsPaint();
    }

    /// A slider from 0 to the star count, for screen readers.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.slider;
        a.number = shown;
        a.min = 0;
        a.max = stars;
        a.step = 1;
        a.allow(AccessAction.increment);
        a.allow(AccessAction.decrement);
        a.allow(AccessAction.setValue);
    }

    /// Steps or sets the value for a screen reader.
    override bool accessAction(ref const AccessRequest r)
    {
        switch (r.action)
        {
        case AccessAction.increment:
            choose(shown + 1);
            return true;
        case AccessAction.decrement:
            choose(shown - 1);
            return true;
        case AccessAction.setValue:
            if (isNaN(r.number))
            {
                return false;
            }
            choose(cast(int) r.number);
            return true;
        default:
            return false;
        }
    }
}
```

What each part is for:

- The constructor sets `interactive` (gets pointer events), `focusable`
  (takes focus on press and Tab) and the cursor, and binds the signal in an
  effect owned by whoever runs the builder.
- `markNeedsPaint()` asks for a repaint of the node's layer. Call
  `markNeedsLayout()` instead when the size may change.
- `performLayout(c)` returns a size within `c`. A node with children lays
  them out with `child.layout(constraints)` and sets their `offset`.
- `paint(ctx, origin)` draws at `origin`. The default paints the children.
- `onPointer` gets `enter`, `move`, `leave`, `down` and `up`. Positions are
  in window coordinates, `bounds` gives the node's own rect. A node that
  saw the press gets the moves and the release. Inside a view that scrolls
  by dragging, a touch press arrives late, and a drag that starts after it
  sends `cancel` and no release: undo what the press started there. A node
  that drags itself, such as a canvas, sets `drags` so its presses are not
  held back and drags its way stay with it.
- `onKey` gets keys while focused. Return false for keys you do not use,
  so they reach the parents and the window's shortcuts.
- `focusRing` is true when focus came from the keyboard, the time to draw a
  ring.
- `describe` tells screen readers what the node is. `accessAction` runs
  their requests. A node left at `Role.none` stays out, and its children
  join the nearest described parent.

`setTooltip`, `accessName` and `owner` come with `Node`.

## Builder and island twin

<!-- src="examples/source/guide/rating.d" from="Rating rating(Signal!int" -->
```d
/// Retained rating: `rating(stars, accessName: "Rating")`.
Rating rating(Signal!int value, int stars = 5, string accessName = null, string tooltip = null)
{
    Rating r = new Rating(value, stars);
    r.accessName = accessName;
    r.setTooltip(tooltip);
    return r;
}
```

The island function declares a paint-only node each pass, with its state
from the island:

<!-- src="examples/source/guide/rating.d" from="bool rating(Ui ui" -->
```d
/// Island rating, true on the pass `value` changed by a click or a key.
bool rating(Ui ui, ref int value, int stars = 5, string file = __FILE__, size_t line = __LINE__)
{
    Id i = ui.id(file, line);
    Press p = ui.clickable(i);
    RatingStyle s = ui.style!RatingStyle(null);
    Rect last = ui.lastRect(i);
    int at = p.hovered ? starAt(s, ui.mouse.x - last.x, stars) : 0;
    int before = value;
    if (p.pressedNow)
    {
        value = at == value ? 0 : at;
    }
    if (ui.focusStop(i))
    {
        value = clamp(value + ui.takeKey(Key.right) - ui.takeKey(Key.left), 0, stars);
    }
    RatingBox b = new RatingBox;
    b.style = s;
    b.stars = stars;
    b.value = value;
    b.hot = at;
    b.ring = ui.focusRing(i);
    ui.put(b);
    ui.track(b, i);
    if (value != before)
    {
        ui.again = true;
    }
    return value != before;
}
```

- `ui.id(file, line)` names the control, from the caller's call site.
- `ui.clickable(id)` gives the pointer state against last pass's rect, and
  `ui.lastRect(id)` that rect.
- `ui.focusStop(id)` makes it a Tab stop, true while focused, and
  `ui.takeKey` takes its keys.
- `ui.put(node)` adds the node, `ui.track(node, id)` records its rect for
  the next pass.
- `ui.again = true` asks for another pass before painting, since the value
  changed after the node was declared.
