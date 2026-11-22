/// Draw output: high-level commands from the UI, anti-aliased triangle meshes for the GPU.
///
/// Front ends emit `DrawCmd` in logical pixels. The tessellator turns them into
/// `Mesh` batches in physical pixels. Anti-aliasing is feathering, as in egui's
/// epaint: a filled shape gets a one pixel ring fading to transparent, so plain
/// alpha blending gives smooth edges without MSAA.
module render;

import layout : Point, Rect;
import std.algorithm.comparison : max;
import std.math : PI, ceil, cos, floor, isClose, round, sin;

/// Premultiplied RGBA8.
struct Color
{
    ubyte r; /// red, premultiplied
    ubyte g; /// green, premultiplied
    ubyte b; /// blue, premultiplied
    ubyte a; /// alpha

    /// Packed as 0xAABBGGRR, the byte order of an RGBA8 vertex attribute.
    uint packed() const
    {
        return r | (g << 8) | (b << 16) | (a << 24);
    }
}

/// Command kinds.
enum Op : ubyte
{
    clip,   /// set the clip rect for following commands
    rect,   /// rounded rect, filled and stroked
    text,   /// shaped glyph run
    image,  /// textured quad
    custom, /// backend callback, for 3D viewports and video
}

/// Filled, optionally stroked, rounded rectangle.
struct RectCmd
{
    Rect r;               /// bounds in logical pixels
    float radius = 0;     /// corner radius
    Color fill;           /// fill color
    Color stroke;         /// outline color
    float strokeWidth = 0; /// outline width, zero for none
}

/// Glyph run laid out by the text system.
struct TextCmd
{
    Point origin; /// baseline start
    uint run;     /// index into the frame's glyph run table
    Color color;  /// text color
}

/// Textured quad.
struct ImageCmd
{
    Rect r;       /// destination
    Rect uv;      /// source in normalized texture coordinates
    uint texture; /// backend texture handle
}

/// One draw command. Small and flat, so a frame is one array.
struct DrawCmd
{
    Op op; /// which member is valid
    union
    {
        Rect clip;      /// for Op.clip
        RectCmd rect;   /// for Op.rect
        TextCmd text;   /// for Op.text
        ImageCmd image; /// for Op.image
        uint callback;  /// for Op.custom
    }
}

static assert(DrawCmd.sizeof <= 48);

/// GPU vertex: physical pixel position, atlas UV, premultiplied color. Same layout as egui's.
struct Vertex
{
    float x; /// position
    float y; /// position
    float u; /// atlas coordinate, white texel for untextured shapes
    float v; /// atlas coordinate
    uint rgba; /// premultiplied color
}

static assert(Vertex.sizeof == 20);

/// Indexed triangles sharing one texture and clip rect.
struct Mesh
{
    Vertex[] vertices; /// vertex buffer
    uint[] indices;    /// three per triangle
}

/// Closed path around `r` with rounded corners, clockwise on screen. Physical pixels.
Point[] roundedRectPath(Rect r, float radius)
{
    if (radius <= 0)
    {
        return [Point(r.x, r.y), Point(r.x + r.w, r.y),
            Point(r.x + r.w, r.y + r.h), Point(r.x, r.y + r.h)];
    }
    int segments = max(2, cast(int) ceil(radius / 2));
    Point[4] centers = [
        Point(r.x + radius, r.y + radius),
        Point(r.x + r.w - radius, r.y + radius),
        Point(r.x + r.w - radius, r.y + r.h - radius),
        Point(r.x + radius, r.y + r.h - radius),
    ];
    Point[] path;
    foreach (size_t corner, Point c; centers)
    {
        double start = PI + corner * PI / 2;
        foreach (int s; 0 .. segments + 1)
        {
            double a = start + s * (PI / 2) / segments;
            path ~= Point(c.x + radius * cos(a), c.y + radius * sin(a));
        }
    }
    return path;
}

/// Fills a convex clockwise path with a `feather` pixel fade to transparent.
void fillConvex(ref Mesh m, const Point[] path, Color c, float feather = 1)
{
    size_t n = path.length;
    uint base = cast(uint) m.vertices.length;
    uint color = c.packed;
    foreach (size_t i; 0 .. n)
    {
        Point prev = path[(i + n - 1) % n];
        Point cur = path[i];
        Point next = path[(i + 1) % n];
        Point n0 = outward(prev, cur);
        Point n1 = outward(cur, next);
        Point avg = Point((n0.x + n1.x) / 2, (n0.y + n1.y) / 2);
        float lenSq = avg.x * avg.x + avg.y * avg.y;
        Point miter = Point(avg.x / lenSq, avg.y / lenSq);
        float h = feather / 2;
        m.vertices ~= Vertex(cur.x - miter.x * h, cur.y - miter.y * h, 0, 0, color);
        m.vertices ~= Vertex(cur.x + miter.x * h, cur.y + miter.y * h, 0, 0, 0);
    }
    foreach (uint i; 1 .. cast(uint) n - 1)
    {
        m.indices ~= [base, base + 2 * i, base + 2 * (i + 1)];
    }
    foreach (uint i; 0 .. cast(uint) n)
    {
        uint j = (i + 1) % cast(uint) n;
        uint ii = base + 2 * i;
        uint jj = base + 2 * j;
        m.indices ~= [ii, ii + 1, jj + 1, ii, jj + 1, jj];
    }
}

/// Unit normal of edge `a` to `b` pointing out of a clockwise path.
private Point outward(Point a, Point b)
{
    float dx = b.x - a.x;
    float dy = b.y - a.y;
    float len = (dx * dx + dy * dy) ^^ 0.5f;
    return Point(dy / len, -dx / len);
}

/// Tessellates a rect command at `ppp` physical pixels per logical pixel.
void tessellate(ref Mesh m, const RectCmd cmd, float ppp)
{
    Rect phys = Rect(cmd.r.x * ppp, cmd.r.y * ppp, cmd.r.w * ppp, cmd.r.h * ppp);
    fillConvex(m, roundedRectPath(phys, cmd.radius * ppp), cmd.fill);
}

/// Glyph cache key: glyph, size in 1/64 px and horizontal subpixel bin.
struct GlyphKey
{
    uint glyph;    /// font glyph index
    uint size64;   /// pixel size times 64
    ubyte bin;     /// horizontal offset, in 1/bins of a pixel
}

/// Cache key for a glyph drawn at physical `x`, and the whole-pixel pen position in `penX`.
GlyphKey glyphKey(uint glyph, float sizePx, float x, out int penX, int bins = 4)
{
    float whole = floor(x);
    int b = cast(int) round((x - whole) * bins);
    if (b == bins)
    {
        b = 0;
        whole += 1;
    }
    penX = cast(int) whole;
    return GlyphKey(glyph, cast(uint) round(sizePx * 64), cast(ubyte) b);
}

/// Logical `v` moved onto the physical pixel grid.
float snap(float v, float ppp)
{
    return round(v * ppp) / ppp;
}

/// Logical `v` moved to a physical pixel center, for crisp one pixel lines.
float snapLine(float v, float ppp)
{
    return (floor(v * ppp) + 0.5f) / ppp;
}

/// Sum of triangle areas where every vertex is opaque.
private double opaqueArea(const Mesh m)
{
    double area = 0;
    for (size_t t = 0; t + 2 < m.indices.length; t += 3)
    {
        const Vertex a = m.vertices[m.indices[t]];
        const Vertex b = m.vertices[m.indices[t + 1]];
        const Vertex c = m.vertices[m.indices[t + 2]];
        if ((a.rgba >> 24) == 255 && (b.rgba >> 24) == 255 && (c.rgba >> 24) == 255)
        {
            double cross = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y);
            area += (cross < 0 ? -cross : cross) / 2;
        }
    }
    return area;
}

/// A square: 4 corners make 8 vertices, 2 fill triangles and 8 fringe triangles.
unittest
{
    Mesh m;
    fillConvex(m, roundedRectPath(Rect(10, 10, 20, 20), 0), Color(255, 255, 255, 255));
    assert(m.vertices.length == 8);
    assert(m.indices.length == 3 * (2 + 8));
    assert(m.vertices[0] == Vertex(10.5, 10.5, 0, 0, 0xFFFF_FFFF), "inner corner, opaque");
    assert(m.vertices[1] == Vertex(9.5, 9.5, 0, 0, 0), "outer corner, transparent");
    assert(opaqueArea(m) == 19.0 * 19.0);
}

/// Rounded corners at 2x scale: the opaque core matches the shape shrunk by half a pixel.
unittest
{
    Mesh m;
    tessellate(m, RectCmd(Rect(0, 0, 50, 30), 6, Color(40, 40, 40, 255)), 2);
    size_t perCorner = 6 + 1;
    assert(m.vertices.length == 2 * 4 * perCorner);
    double full = 100.0 * 60 - (4 - PI) * 12 * 12;
    double area = opaqueArea(m);
    assert(area > full - 170 && area < full - 150, "about a half pixel ring removed");
}

/// Subpixel bins: four horizontal offsets per glyph, rounding up into the next pixel.
unittest
{
    int pen;
    assert(glyphKey(42, 13, 10.0, pen).bin == 0 && pen == 10);
    assert(glyphKey(42, 13, 10.3, pen).bin == 1 && pen == 10);
    assert(glyphKey(42, 13, 10.9, pen).bin == 0 && pen == 11);
    assert(glyphKey(42, 13, 0, pen).size64 == 832);
}

/// DPI: snapping at 150 percent.
unittest
{
    assert(snap(10.2, 1.5) == 10);
    assert(isClose(snapLine(10, 1.5) * 1.5, 15.5, 1e-6));
}
