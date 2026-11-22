/// CPU renderer: rasterizes a `FrameMesh` into RGBA8 pixels.
///
/// Follows the GL backend: pixel centers at half pixels, the top-left fill rule, bilinear texture sampling with
/// clamped edges, premultiplied blending in the framebuffer's gamma space and an opaque framebuffer. Custom draw
/// batches are skipped. NOTE: channels can differ from GL's by a level where colors are interpolated.
module dentrite.backend.software;

import dentrite.draw;
import dentrite.geom;
import dentrite.image : Image;
import dentrite.platform : Renderer;
import dentrite.text : GlyphAtlas;
import std.algorithm.comparison : max, min;
import std.math : abs, floor, round;

version (LittleEndian)
{
}
else
{
    static assert(false, "pixels are read as 0xAABBGGRR words");
}

/// Draws frames into `pixels`.
final class SoftwareRenderer : Renderer
{
    uint[] pixels; /// last frame as 0xAABBGGRR, rows top first
    int width;     /// frame width in physical pixels
    int height;    /// frame height in physical pixels

    /// Clears to `clear` and draws the triangle batches of `mesh`.
    void render(FrameMesh mesh, GlyphAtlas atlas, Color clear)
    {
        width = mesh.width;
        height = mesh.height;
        if (pixels.length != cast(size_t) width * height)
        {
            pixels = new uint[cast(size_t) width * height];
        }
        pixels[] = clear.r | clear.g << 8 | clear.b << 16 | 0xff000000;
        Texture glyphs = Texture(cast(const(uint)[]) atlas.pixels, atlas.width, atlas.height);
        PixelRect screen = PixelRect(0, 0, width, height);
        foreach (ref const Batch b; mesh.batches)
        {
            PixelRect clip = intersectPixels(b.clip, screen);
            if (b.callback !is null || b.layer !is null || clip.empty)
            {
                continue;
            }
            Texture tex = glyphs;
            if (b.image !is null)
            {
                Image img = cast(Image) b.image;
                if (img.empty)
                {
                    continue;
                }
                tex = Texture(cast(const(uint)[]) img.pixels, img.width, img.height);
            }
            const FrameMesh src = b.source is null ? mesh : b.source;
            foreach (uint i; b.start / 3 .. (b.start + b.count) / 3)
            {
                const(uint)[] t = src.indices[i * 3 .. i * 3 + 3];
                Vertex[3] v = [src.vertices[t[0]], src.vertices[t[1]], src.vertices[t[2]]];
                if (b.dx != 0 || b.dy != 0)
                {
                    foreach (ref Vertex c; v)
                    {
                        c.x += b.dx;
                        c.y += b.dy;
                    }
                }
                triangle(v[0], v[1], v[2], clip, tex);
            }
        }
    }

    /// Copy of the last frame as RGBA8 rows.
    ubyte[] readPixels()
    {
        return (cast(ubyte[]) pixels).dup;
    }

    /// Name for logs.
    string description()
    {
        return "software renderer";
    }

    /// Nothing to free.
    void dispose()
    {
    }

    /// Fills the pixels of triangle `a b c` inside `clip`.
    private void triangle(ref const Vertex a, ref const Vertex b, ref const Vertex c, PixelRect clip,
        ref const Texture tex)
    {
        long ax = fixed(a.x);
        long ay = fixed(a.y);
        long bx = fixed(b.x);
        long by = fixed(b.y);
        long cx = fixed(c.x);
        long cy = fixed(c.y);
        long area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
        if (area == 0)
        {
            return;
        }
        const(Vertex)* pa = &a;
        const(Vertex)* pb = &b;
        const(Vertex)* pc = &c;
        if (area < 0)
        {
            pb = &c;
            pc = &b;
            long tx = bx;
            long ty = by;
            bx = cx;
            by = cy;
            cx = tx;
            cy = ty;
        }
        int x0 = max(clip.x, cast(int) ceilDiv(min(ax, bx, cx) - half, one));
        int x1 = min(clip.x + clip.w - 1, cast(int) floorDiv(max(ax, bx, cx) - half, one));
        int y0 = max(clip.y, cast(int) ceilDiv(min(ay, by, cy) - half, one));
        int y1 = min(clip.y + clip.h - 1, cast(int) floorDiv(max(ay, by, cy) - half, one));
        if (x0 > x1 || y0 > y1)
        {
            return;
        }
        Edge[3] edges = [Edge(ax, ay, bx, by), Edge(bx, by, cx, cy), Edge(cx, cy, ax, ay)];
        Shading s = Shading(*pa, *pb, *pc);
        bool sameColor = a.rgba == b.rgba && b.rgba == c.rgba;
        bool sameUV = a.u == b.u && b.u == c.u && a.v == b.v && b.v == c.v;
        int offU;
        int offV;
        bool nearest = sameUV == false && s.texelAligned(offU, offV);
        foreach (int y; y0 .. y1 + 1)
        {
            long l = x0;
            long r = x1;
            bool empty;
            foreach (ref const Edge e; edges)
            {
                long er = e.e0 + y * e.sy;
                if (e.sx > 0)
                {
                    l = max(l, ceilDiv(e.bias - er, e.sx));
                }
                else if (e.sx < 0)
                {
                    r = min(r, floorDiv(er - e.bias, -e.sx));
                }
                else if (er < e.bias)
                {
                    empty = true;
                }
            }
            if (empty || l > r)
            {
                continue;
            }
            size_t at = cast(size_t) y * width;
            uint[] row = pixels[at + cast(size_t) l .. at + cast(size_t) r + 1];
            if (sameColor && sameUV)
            {
                span!(false, false, false)(row, s, cast(int) l, y, tex, 0, 0);
            }
            else if (sameColor && nearest)
            {
                span!(false, true, true)(row, s, cast(int) l, y, tex, offU, offV);
            }
            else if (sameColor)
            {
                span!(false, true, false)(row, s, cast(int) l, y, tex, 0, 0);
            }
            else if (sameUV)
            {
                span!(true, false, false)(row, s, cast(int) l, y, tex, 0, 0);
            }
            else if (nearest)
            {
                span!(true, true, true)(row, s, cast(int) l, y, tex, offU, offV);
            }
            else
            {
                span!(true, true, false)(row, s, cast(int) l, y, tex, 0, 0);
            }
        }
    }
}

/// Fractional bits of fixed point positions.
private enum int subBits = 8;
/// One pixel in fixed point.
private enum long one = 1L << subBits;
/// Half a pixel in fixed point.
private enum long half = one / 2;

/// `v` pixels in fixed point, rounded.
private long fixed(float v)
{
    return cast(long) floor(cast(double) v * one + 0.5);
}

/// `a / b` rounded down, for `b > 0`.
private long floorDiv(long a, long b)
{
    return a >= 0 ? a / b : -((-a + b - 1) / b);
}

/// `a / b` rounded up, for `b > 0`.
private long ceilDiv(long a, long b)
{
    return a >= 0 ? (a + b - 1) / b : -((-a) / b);
}

/// Edge function of a directed triangle edge at pixel centers: inside where `e0 + x * sx + y * sy >= bias`.
private struct Edge
{
    long e0;   /// value at the center of pixel 0, 0
    long sx;   /// change per pixel to the right
    long sy;   /// change per pixel down
    long bias; /// 0 on top and left edges, which own the pixel centers they pass through, else 1

    /// Edge from `p` to `q`, triangle interior on the side where the function is positive.
    this(long px, long py, long qx, long qy)
    {
        long dx = qx - px;
        long dy = qy - py;
        e0 = dx * (half - py) - dy * (half - px);
        sx = -dy * one;
        sy = dx * one;
        bias = dy < 0 || (dy == 0 && dx > 0) ? 0 : 1;
    }
}

/// Attribute planes of a triangle: color and texel coordinates as functions of the pixel position.
private struct Shading
{
    float[6] at;  /// r, g, b, a, u, v at the center of pixel 0, 0
    float[6] dx;  /// change per pixel to the right
    float[6] dy;  /// change per pixel down

    /// Planes through the vertices.
    this(ref const Vertex a, ref const Vertex b, ref const Vertex c)
    {
        float[6] va = attributes(a);
        float[6] vb = attributes(b);
        float[6] vc = attributes(c);
        float bx = b.x - a.x;
        float by = b.y - a.y;
        float cx = c.x - a.x;
        float cy = c.y - a.y;
        float det = bx * cy - cx * by;
        foreach (int i; 0 .. 6)
        {
            float db = vb[i] - va[i];
            float dc = vc[i] - va[i];
            dx[i] = (db * cy - dc * by) / det;
            dy[i] = (dc * bx - db * cx) / det;
            at[i] = va[i] + dx[i] * (0.5f - a.x) + dy[i] * (0.5f - a.y);
        }
    }

    /// Color channels and texel coordinates of `v`.
    static float[6] attributes(ref const Vertex v)
    {
        return [v.rgba & 0xff, (v.rgba >> 8) & 0xff, (v.rgba >> 16) & 0xff, v.rgba >> 24, v.u, v.v];
    }

    /// True if texels map one to one onto pixels with centers on texel centers, setting the texel offsets.
    bool texelAligned(out int offU, out int offV) const
    {
        enum float eps = 1e-3f;
        if (abs(dx[4] - 1) > eps || abs(dy[4]) > eps || abs(dx[5]) > eps || abs(dy[5] - 1) > eps)
        {
            return false;
        }
        float u = at[4] - 0.5f;
        float v = at[5] - 0.5f;
        if (abs(u - round(u)) > eps || abs(v - round(v)) > eps)
        {
            return false;
        }
        offU = cast(int) round(u);
        offV = cast(int) round(v);
        return true;
    }
}

/// Atlas or image texels with clamped lookups.
private struct Texture
{
    const(uint)[] texels; /// 0xAABBGGRR rows
    int w;                /// width
    int h;                /// height

    /// Texel at `x, y`, clamped to the edges.
    uint at(int x, int y) const
    {
        x = x < 0 ? 0 : (x >= w ? w - 1 : x);
        y = y < 0 ? 0 : (y >= h ? h - 1 : y);
        return texels[cast(size_t) y * w + x];
    }

    /// Bilinear sample at texel coordinates `u, v` into `o` as r, g, b, a in 0 to 255.
    void sample(float u, float v, ref float[4] o) const
    {
        float s = u - 0.5f;
        float t = v - 0.5f;
        float fs = floor(s);
        float ft = floor(t);
        int i = cast(int) fs;
        int j = cast(int) ft;
        float wx = s - fs;
        float wy = t - ft;
        uint t00 = at(i, j);
        uint t10 = at(i + 1, j);
        uint t01 = at(i, j + 1);
        uint t11 = at(i + 1, j + 1);
        foreach (int k; 0 .. 4)
        {
            int sh = k * 8;
            float top = ((t00 >> sh) & 0xff) * (1 - wx) + ((t10 >> sh) & 0xff) * wx;
            float bottom = ((t01 >> sh) & 0xff) * (1 - wx) + ((t11 >> sh) & 0xff) * wx;
            o[k] = top * (1 - wy) + bottom * wy;
        }
    }
}

/// Shades and blends `row`, pixels `x` onward of row `y`. Colors and texel coordinates come from the planes
/// where they vary, texels from `offU, offV` when `nearest`.
private void span(bool varyColor, bool varyUV, bool nearest)(uint[] row, ref const Shading s, int x, int y,
    ref const Texture tex, int offU, int offV)
{
    float[6] p;
    foreach (int i; 0 .. 6)
    {
        p[i] = s.at[i] + s.dx[i] * x + s.dy[i] * y;
    }
    float[4] t = [255, 255, 255, 255];
    static if (varyUV == false)
    {
        tex.sample(p[4], p[5], t);
    }
    const(uint)[] texRow;
    static if (nearest)
    {
        int ty = y + offV;
        ty = ty < 0 ? 0 : (ty >= tex.h ? tex.h - 1 : ty);
        texRow = tex.texels[cast(size_t) ty * tex.w .. cast(size_t)(ty + 1) * tex.w];
    }
    float[4] src;
    foreach (int k; 0 .. 4)
    {
        src[k] = p[k] * t[k] * (1 / 255.0f);
    }
    static if (varyColor == false && varyUV == false)
    {
        if (src[3] > 254.99f)
        {
            row[] = to8(src[0]) | to8(src[1]) << 8 | to8(src[2]) << 16 | 0xff000000;
            return;
        }
    }
    foreach (size_t i, ref uint d; row)
    {
        static if (nearest)
        {
            int tx = x + cast(int) i + offU;
            uint texel = texRow[tx < 0 ? 0 : (tx >= tex.w ? tex.w - 1 : tx)];
            foreach (int k; 0 .. 4)
            {
                t[k] = (texel >> (k * 8)) & 0xff;
            }
        }
        else static if (varyUV)
        {
            tex.sample(p[4] + s.dx[4] * i, p[5] + s.dx[5] * i, t);
        }
        static if (varyColor || varyUV)
        {
            foreach (int k; 0 .. 4)
            {
                float c = varyColor ? p[k] + s.dx[k] * i : p[k];
                src[k] = c * t[k] * (1 / 255.0f);
            }
        }
        if (src[3] > 254.99f)
        {
            d = to8(src[0]) | to8(src[1]) << 8 | to8(src[2]) << 16 | 0xff000000;
        }
        else if (src[3] > 0 || src[0] > 0 || src[1] > 0 || src[2] > 0)
        {
            float k = 1 - src[3] * (1 / 255.0f);
            d = to8(src[0] + (d & 0xff) * k) | to8(src[1] + ((d >> 8) & 0xff) * k) << 8
                | to8(src[2] + ((d >> 16) & 0xff) * k) << 16 | 0xff000000;
        }
    }
}

/// Channel value rounded and clamped to a byte.
private uint to8(float v)
{
    int i = cast(int)(v + 0.5f);
    return i < 0 ? 0 : (i > 255 ? 255 : i);
}

// Quads cover the pixels whose centers they contain, a translucent quad blends once along its diagonal,
// clips cut, and glyph texels map one to one.
unittest
{
    GlyphAtlas atlas = new GlyphAtlas(64, 64);
    atlas.pixels[(10 * 64 + 10) * 4 .. (10 * 64 + 10) * 4 + 4] = 0x40;
    atlas.pixels[(10 * 64 + 11) * 4 .. (10 * 64 + 11) * 4 + 4] = 0xff;
    FrameMesh m = new FrameMesh;
    m.width = 8;
    m.height = 8;
    void quad(float x0, float y0, float x1, float y1, uint rgba, float u0 = 2, float v0 = 2, float u1 = 2,
        float v1 = 2)
    {
        uint b = cast(uint) m.vertices.length;
        m.vertices ~= [Vertex(x0, y0, u0, v0, rgba), Vertex(x1, y0, u1, v0, rgba), Vertex(x1, y1, u1, v1, rgba),
            Vertex(x0, y1, u0, v1, rgba)];
        m.indices ~= [b, b + 1, b + 2, b, b + 2, b + 3];
    }

    quad(1, 1, 3, 3, 0xff0000ff);
    quad(4, 0, 8, 4, 0x80808080);
    quad(5, 5, 7, 6, 0xffffffff, 10, 10, 12, 11);
    m.batches ~= Batch(PixelRect(0, 0, 8, 8), 0, cast(uint) m.indices.length);
    quad(0, 6, 8, 8, 0xff00ff00);
    m.batches ~= Batch(PixelRect(0, 7, 2, 1), 18, 6);
    SoftwareRenderer r = new SoftwareRenderer;
    r.render(m, atlas, Color(0, 0, 0, 255));
    uint px(int x, int y)
    {
        return r.pixels[y * 8 + x];
    }

    assert(px(1, 1) == 0xff0000ff && px(2, 2) == 0xff0000ff);
    assert(px(0, 1) == 0xff000000 && px(3, 2) == 0xff000000 && px(1, 3) == 0xff000000 && px(1, 0) == 0xff000000);
    foreach (int y; 0 .. 4)
    {
        foreach (int x; 4 .. 8)
        {
            assert(px(x, y) == 0xff808080, "half white once, no seam");
        }
    }
    assert(px(5, 5) == 0xff404040 && px(6, 5) == 0xffffffff, "texels one to one");
    assert(px(0, 7) == 0xff00ff00 && px(1, 7) == 0xff00ff00 && px(2, 7) == 0xff000000 && px(0, 6) == 0xff000000);
}

// A fade ramps a rect to transparent at both edges, linear in x, and leaves the middle alone.
unittest
{
    DrawList l;
    l.pushFade(Rect(0, 0, 100, 10), 20, 40);
    l.rect(Rect(0, 0, 100, 10), Color(255, 255, 255, 255));
    l.popFade();
    l.rect(Rect(0, 10, 100, 10), Color(255, 255, 255, 255));
    FrameMesh m = new FrameMesh;
    Tessellator t;
    t.run(l, m, 100, 20);
    SoftwareRenderer r = new SoftwareRenderer;
    r.render(m, new GlyphAtlas(64, 64), Color(0, 0, 0, 255));
    foreach (int x; 2 .. 98)
    {
        float k = x < 20 ? (x + 0.5f) / 20 : x >= 60 ? (100 - x - 0.5f) / 40 : 1;
        int red = r.pixels[5 * 100 + x] & 0xff;
        assert(abs(red - k * 255) <= 2, "faded");
        assert((r.pixels[15 * 100 + x] & 0xff) == 255, "not faded after popFade");
    }
}

// Images sample their own texels: one to one, stretched from a source rect, and tinted. Shapes after them
// sample the atlas again.
unittest
{
    Image img = new Image(2, 2);
    img.set(0, 0, 255, 0, 0, 255);
    img.set(1, 0, 0, 255, 0, 255);
    img.set(0, 1, 0, 0, 255, 255);
    img.set(1, 1, 255, 255, 255, 128);
    DrawList l;
    l.image(Rect(1, 1, 2, 2), img);
    l.image(Rect(4, 0, 4, 4), img, Color(255, 255, 255, 255), Rect(0, 0, 1, 1));
    l.image(Rect(0, 4, 2, 2), img, Color(255, 255, 255, 128));
    l.rect(Rect(4, 4, 2, 2), Color(0, 255, 255, 255));
    FrameMesh m = new FrameMesh;
    Tessellator t;
    t.run(l, m, 8, 8);
    SoftwareRenderer r = new SoftwareRenderer;
    r.render(m, new GlyphAtlas(64, 64), Color(0, 0, 0, 255));
    uint px(int x, int y)
    {
        return r.pixels[y * 8 + x];
    }

    assert(px(1, 1) == 0xff0000ff && px(2, 1) == 0xff00ff00 && px(1, 2) == 0xffff0000);
    assert(px(2, 2) == 0xff808080, "half white over black");
    assert(px(0, 1) == 0xff000000 && px(3, 3) == 0xff000000);
    assert(px(4, 0) == 0xff0000ff && px(5, 1) == 0xff0000ff, "red texel stretched");
    assert(px(0, 4) == 0xff000080, "tinted to half");
    assert(px(4, 4) == 0xffffff00 && px(5, 5) == 0xffffff00);
}
