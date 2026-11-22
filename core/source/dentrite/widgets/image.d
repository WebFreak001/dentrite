/// Picture views: an `Image` scaled into a box, kept whole, covering it, stretched or at its own size.
module dentrite.widgets.image;

import dentrite.image : Image;
import dentrite.immediate;
import dentrite.node;
import dentrite.signals : effect;
import std.algorithm.comparison : max, min;

/// How a picture fills its box.
enum Fit
{
    contain, /// as large as fits whole, aspect kept, centered
    cover,   /// fills the box, aspect kept, centered, the overflow cut
    fill,    /// stretched to the box
    none,    /// natural size, centered, the overflow cut
}

/// Logical size of `img` drawn `density` image pixels to a logical pixel, zero for none.
Size naturalSize(const Image img, float density)
{
    if (img is null || img.empty)
    {
        return Size(0, 0);
    }
    float d = density > 0 ? density : 1;
    return Size(img.width / d, img.height / d);
}

/// Size of a picture with `natural` size under `c`: natural, shrunk with its aspect kept to fit the largest
/// size, then grown to the smallest.
Size measureImage(Constraints c, Size natural)
{
    Size s = natural;
    if (s.w > c.maxW)
    {
        s = Size(c.maxW, s.h * c.maxW / s.w);
    }
    if (s.h > c.maxH)
    {
        s = Size(s.w * c.maxH / s.h, c.maxH);
    }
    return c.constrain(s);
}

/// Where a picture with `natural` size goes in `box` for `fit`, larger than the box for `cover` and `none`.
Rect fitRect(Rect box, Size natural, Fit fit)
{
    if (fit == Fit.fill || natural.w <= 0 || natural.h <= 0)
    {
        return box;
    }
    float k = 1;
    if (fit == Fit.contain)
    {
        k = min(box.w / natural.w, box.h / natural.h);
    }
    else if (fit == Fit.cover)
    {
        k = max(box.w / natural.w, box.h / natural.h);
    }
    float w = natural.w * k;
    float h = natural.h * k;
    return Rect(box.x + (box.w - w) / 2, box.y + (box.h - h) / 2, w, h);
}

/// Paints `img` into `box` for `fit` and `density`, times `tint`, cutting what falls outside. Shared by the
/// retained node and the island function.
void paintImage(ref PaintContext ctx, Rect box, Image img, Fit fit, float density, Color tint)
{
    Size natural = naturalSize(img, density);
    if (natural.w <= 0 || box.empty)
    {
        return;
    }
    Rect at = fitRect(box, natural, fit);
    Rect shown = intersect(at, box);
    if (shown.empty)
    {
        return;
    }
    float sx = img.width / at.w;
    float sy = img.height / at.h;
    Rect source = Rect((shown.x - at.x) * sx, (shown.y - at.y) * sy, shown.w * sx, shown.h * sy);
    ctx.list.image(shown, img, tint, source);
}

/// A picture with a name for screen readers, or nothing to them without one.
private void describeImage(ref AccessInfo a, Node n)
{
    a.role = n.accessName !is null || n.tooltip !is null ? Role.image : Role.none;
}

/// Retained picture. Build it with `imageView`.
final class ImageView : Node
{
    private Image shown; /// image last read
    Fit fit;             /// how it fills the box
    float density;       /// image pixels per logical pixel
    Color tint;          /// color multiplied into every pixel, white for none

    /// Creates a view following `image`. The binding effect belongs to the current owner.
    this(Image delegate() image, Fit fit, float density, Color tint)
    {
        this.fit = fit;
        this.density = density;
        this.tint = tint;
        effect(() {
            Image i = image();
            if (i is shown)
            {
                return;
            }
            bool resized = naturalSize(i, density) != naturalSize(shown, density);
            shown = i;
            if (resized)
            {
                markNeedsLayout();
            }
            else
            {
                markNeedsPaint();
            }
        });
    }

    /// Image shown, or null.
    Image image()
    {
        return shown;
    }

    /// An image when named by `accessName` or a tooltip.
    override void describe(ref AccessInfo a)
    {
        describeImage(a, this);
    }

    /// Natural size, shrunk to fit with its aspect kept.
    protected override Size performLayout(Constraints c)
    {
        return measureImage(c, naturalSize(shown, density));
    }

    /// The picture.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintImage(ctx, Rect(origin.x, origin.y, size.w, size.h), shown, fit, density, tint);
    }
}

/// Retained picture following `image`: `imageView(() => thumb.get, Fit.cover)`. `density` is image pixels per
/// logical pixel, 2 for a picture made for a 2x display. Unnamed pictures stay out of the accessibility tree.
/// NOTE: after changing pixels in place, call `Image.changed` and `markNeedsPaint` on the view.
ImageView imageView(Image delegate() image, Fit fit = Fit.contain, float density = 1,
    Color tint = Color(255, 255, 255, 255), string accessName = null)
{
    ImageView v = new ImageView(image, fit, density, tint);
    v.accessName = accessName;
    return v;
}

/// Retained picture of a fixed `image`.
ImageView imageView(Image image, Fit fit = Fit.contain, float density = 1, Color tint = Color(255, 255, 255, 255),
    string accessName = null)
{
    return imageView(() => image, fit, density, tint, accessName);
}

/// Paint-only picture declared by an island pass.
final class ImageBox : Node
{
    Image image;   /// picture to draw
    Fit fit;       /// how it fills the box
    float density; /// image pixels per logical pixel
    Color tint;    /// color multiplied into every pixel, white for none

    /// Creates a box.
    this(Image image, Fit fit, float density, Color tint)
    {
        this.image = image;
        this.fit = fit;
        this.density = density;
        this.tint = tint;
    }

    /// An image when named.
    override void describe(ref AccessInfo a)
    {
        describeImage(a, this);
    }

    /// Same size as the retained view.
    protected override Size performLayout(Constraints c)
    {
        return measureImage(c, naturalSize(image, density));
    }

    /// Same look as the retained view.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintImage(ctx, Rect(origin.x, origin.y, size.w, size.h), image, fit, density, tint);
    }
}

/// Island picture, as the retained `imageView`.
void imageView(Ui ui, Image image, Fit fit = Fit.contain, float density = 1, Color tint = Color(255, 255, 255, 255),
    string accessName = null)
{
    ImageBox b = new ImageBox(image, fit, density, tint);
    b.accessName = accessName;
    ui.put(b);
}

// Sizes follow the picture and its aspect, fits place it, and the source rect cuts what overflows.
unittest
{
    import dentrite.draw : DrawList;

    Image img = new Image(40, 20);
    assert(naturalSize(img, 2) == Size(20, 10) && naturalSize(null, 1) == Size(0, 0));
    assert(measureImage(Constraints.loose(Size(100, 100)), Size(40, 20)) == Size(40, 20));
    assert(measureImage(Constraints.loose(Size(20, 100)), Size(40, 20)) == Size(20, 10), "shrunk with the aspect");
    assert(measureImage(Constraints.loose(Size(100, 5)), Size(40, 20)) == Size(10, 5));
    assert(measureImage(Constraints.tight(Size(30, 30)), Size(40, 20)) == Size(30, 30));

    Rect box = Rect(10, 10, 100, 100);
    assert(fitRect(box, Size(40, 20), Fit.contain) == Rect(10, 35, 100, 50));
    assert(fitRect(box, Size(40, 20), Fit.cover) == Rect(-40, 10, 200, 100));
    assert(fitRect(box, Size(40, 20), Fit.fill) == box);
    assert(fitRect(box, Size(40, 20), Fit.none) == Rect(40, 50, 40, 20));

    DrawList list;
    PaintContext ctx;
    ctx.list = &list;
    Color white = Color(255, 255, 255, 255);
    paintImage(ctx, box, img, Fit.cover, 1, white);
    assert(list.cmds[0].r == box && list.cmds[0].source == Rect(10, 0, 20, 20), "the middle half");
    list.clear();
    paintImage(ctx, Rect(0, 0, 20, 10), img, Fit.none, 1, white);
    assert(list.cmds[0].r == Rect(0, 0, 20, 10) && list.cmds[0].source == Rect(10, 5, 20, 10));
    list.clear();
    paintImage(ctx, box, img, Fit.contain, 1, white);
    assert(list.cmds[0].source == Rect(0, 0, 40, 20));
    list.clear();
    paintImage(ctx, box, null, Fit.contain, 1, white);
    assert(list.cmds.length == 0);
}

// A retained view and an island picture draw the same pixels, follow a new image, and only named ones
// reach screen readers.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : expanded, row;
    import dentrite.host : Host;
    import dentrite.island : Island, island;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(200, 100);
    scope (exit)
    {
        h.close();
    }
    Image a = new Image(4, 2);
    foreach (int x; 0 .. 4)
    {
        a.set(x, 0, 255, 0, 0, 255);
        a.set(x, 1, 0, 0, 255, 255);
    }
    Image b = new Image(6, 6);
    foreach (int y; 0 .. 6)
    {
        foreach (int x; 0 .. 6)
        {
            b.set(x, y, 0, 255, 0, 255);
        }
    }
    Signal!Image pic = signal(a);
    ImageView v = imageView(() => pic.get, accessName: "Red over blue");
    Island isl = island((Ui ui) { ui.imageView(a, density: 0.5); });
    h.setRoot(row()(v, expanded(isl)));
    h.frame();
    SoftwareRenderer r = cast(SoftwareRenderer) h.renderer;
    uint px(float x, float y)
    {
        return r.pixels[cast(int) y * r.width + cast(int) x];
    }

    assert(v.size == Size(4, 2));
    Rect vb = v.bounds;
    assert(px(vb.x, vb.y) == 0xff0000ff && px(vb.right - 1, vb.y + 1) == 0xffff0000);
    Rect ib = isl.bounds;
    float x0 = ib.x + (ib.w - 8) / 2;
    assert(px(x0, ib.y) == 0xff0000ff && px(x0 + 7, ib.y + 3) == 0xffff0000, "two pixels per image pixel");
    assert(px(x0 - 1, ib.y) != 0xff0000ff && px(x0 + 8, ib.y) != 0xff0000ff && px(x0, ib.y + 4) != 0xffff0000);
    AccessInfo named;
    v.describe(named);
    AccessInfo plain;
    imageView(a).describe(plain);
    assert(named.role == Role.image && plain.role == Role.none);

    pic.set(b);
    h.frame();
    assert(v.size == Size(6, 6) && px(v.bounds.x + 5, v.bounds.y + 5) == 0xff00ff00, "new size and pixels");
}
