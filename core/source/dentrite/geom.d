/// Geometry and color types shared by layout, drawing and themes. Logical pixels unless noted.
module dentrite.geom;

import std.algorithm.comparison : max, min;

/// Width and height, in logical pixels unless documented as physical.
struct Size
{
    float w = 0; /// width
    float h = 0; /// height
}

/// Position, in logical pixels unless documented as physical.
struct Point
{
    float x = 0; /// horizontal
    float y = 0; /// vertical

    /// Component-wise sum or difference.
    Point opBinary(string op)(Point o) const if (op == "+" || op == "-")
    {
        return Point(mixin("x " ~ op ~ " o.x"), mixin("y " ~ op ~ " o.y"));
    }
}

/// Axis-aligned rectangle, in logical pixels unless documented as physical.
struct Rect
{
    float x = 0; /// left
    float y = 0; /// top
    float w = 0; /// width
    float h = 0; /// height

    /// Right edge.
    float right() const
    {
        return x + w;
    }

    /// Bottom edge.
    float bottom() const
    {
        return y + h;
    }

    /// True if `p` lies inside, right and bottom edges excluded.
    bool contains(Point p) const
    {
        return p.x >= x && p.y >= y && p.x < x + w && p.y < y + h;
    }

    /// True if the area is zero.
    bool empty() const
    {
        return w <= 0 || h <= 0;
    }

    /// Rect shrunk by `i`.
    Rect inset(Insets i) const
    {
        return Rect(x + i.left, y + i.top, max(0f, w - i.left - i.right), max(0f, h - i.top - i.bottom));
    }

    /// Rect shrunk by `d` on every side, or grown for negative `d`.
    Rect inset(float d) const
    {
        return inset(Insets.all(d));
    }

    /// Rect moved by `p`.
    Rect translate(Point p) const
    {
        return Rect(x + p.x, y + p.y, w, h);
    }

    /// Top-left corner.
    Point pos() const
    {
        return Point(x, y);
    }
}

/// Intersection of two rects, empty if they do not overlap.
Rect intersect(Rect a, Rect b)
{
    float x0 = max(a.x, b.x);
    float y0 = max(a.y, b.y);
    float x1 = min(a.x + a.w, b.x + b.w);
    float y1 = min(a.y + a.h, b.y + b.h);
    return Rect(x0, y0, max(0f, x1 - x0), max(0f, y1 - y0));
}

/// Space around a child, in logical pixels.
struct Insets
{
    float left = 0;   /// left inset
    float top = 0;    /// top inset
    float right = 0;  /// right inset
    float bottom = 0; /// bottom inset

    /// Same inset on all four sides.
    static Insets all(float v)
    {
        return Insets(v, v, v, v);
    }

    /// `x` left and right, `y` top and bottom.
    static Insets xy(float x, float y)
    {
        return Insets(x, y, x, y);
    }
}

/// RGBA color, 8 bits per channel, straight alpha. `Color.init` is transparent.
struct Color
{
    ubyte r; /// red
    ubyte g; /// green
    ubyte b; /// blue
    ubyte a; /// alpha

    /// Premultiplied and packed as 0xAABBGGRR, the byte order of an RGBA8 vertex attribute.
    uint premul() const
    {
        uint pr = (r * a + 127) / 255;
        uint pg = (g * a + 127) / 255;
        uint pb = (b * a + 127) / 255;
        return pr | (pg << 8) | (pb << 16) | (a << 24);
    }

    /// Same color with alpha scaled by `f`.
    Color fade(float f) const
    {
        return Color(r, g, b, cast(ubyte)(a * f + 0.5f));
    }

    /// Linear mix toward `o` by `t` in 0 to 1.
    Color mix(Color o, float t) const
    {
        ubyte lerp(ubyte p, ubyte q)
        {
            return cast(ubyte)(p + (q - p) * t + 0.5f);
        }

        return Color(lerp(r, o.r), lerp(g, o.g), lerp(b, o.b), lerp(a, o.a));
    }
}

/// Premultiplying keeps opaque colors and scales translucent ones.
unittest
{
    assert(Color(255, 128, 0, 255).premul == 0xFF0080FF);
    assert(Color(255, 255, 255, 128).premul == 0x80808080);
    assert(Color.init.premul == 0);
}
