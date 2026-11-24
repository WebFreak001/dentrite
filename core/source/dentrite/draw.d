/// Draw output: commands in logical pixels from the UI, triangle meshes in physical pixels for a backend.
///
/// Anti-aliasing is feathering, as in egui's epaint: every edge gets a one pixel
/// fade to transparent, so plain alpha blending gives smooth edges without MSAA.
/// Rect edges are snapped to whole physical pixels, so axis-aligned edges stay
/// crisp. Every shape samples the glyph atlas through its white block, so a batch
/// only ends at a clip change, a custom draw or an image, which samples its own
/// texture. Backends (GL now, software and Vulkan later) only see `FrameMesh`.
///
/// Frames are composed from layers, one per paint boundary. A layer keeps its
/// commands and their mesh, and is recorded and tessellated again only when it is
/// dirty. A layer that moved by whole physical pixels is drawn from its mesh with a
/// shift, which gives the same pixels as tessellating it at the new place.
module dentrite.draw;

import core.time : Duration, MonoTime;
import dentrite.geom;
import dentrite.image : Image;
import dentrite.text;
import std.algorithm.comparison : clamp, max, min;
import std.math : PI, abs, ceil, cos, floor, round, sin, sqrt;

/// Renderer callback for a custom draw, such as a 3D view: physical area and clip, origin top left,
/// and the framebuffer size. Only the GL renderer calls it.
alias CustomDraw = void delegate(Rect area, Rect clip, Size framebuffer);

/// Kinds of draw command. Each doc names the `DrawCmd` fields it reads.
enum Op : ubyte
{
    pushClip, /// intersect the clip with `r`
    popClip,  /// restore the previous clip
    rect,     /// rounded rect, filled and stroked
    shadow,   /// soft rounded rect, `width` is the blur
    polyline, /// open stroked path through `points`
    polygon,  /// filled convex path, clockwise on screen
    text,     /// glyphs `[first, last)` of `run` at `origin`
    custom,   /// backend callback over `r`
    layer,    /// child `layer` with bounds `r`, composed from its own mesh
    pushFade, /// fade later shapes to transparent over `width` inside the left edge of `r` and `right` inside its right
    popFade,  /// end the innermost `pushFade`
    image,    /// `source` pixels of `image` stretched over `r`, times `fill`
}

/// One draw command. Fields not used by `op` stay at their defaults.
struct DrawCmd
{
    Op op;              /// kind of command
    Rect r;             /// rect, shadow, clip or custom area
    float radius = 0;   /// corner radius
    Color fill;         /// fill color, or the text color for text
    Color stroke;       /// outline color
    float width = 0;    /// stroke width, line width, shadow blur or left fade
    float right = 0;    /// fade width inside the right edge, for `Op.pushFade`
    Point[] points;     /// polyline and polygon points
    ShapedRun run;      /// shaped text to draw
    size_t first;       /// index of the first glyph of `run` to draw
    size_t last;        /// index one past the last glyph of `run` to draw
    float shift = 0;    /// run x of the first glyph, physical pixels
    Point origin;       /// start of the text baseline
    CustomDraw callback; /// backend callback for `Op.custom`
    Layer layer;        /// child layer
    Image image;        /// picture for `Op.image`
    Rect source;        /// image pixels drawn, empty for all of them
}

/// Commands of a frame or of a cached part of one, in paint order.
struct DrawList
{
    DrawCmd[] cmds; /// commands in paint order

    /// Removes every command, keeping the memory.
    void clear()
    {
        cmds.length = 0;
        cmds.assumeSafeAppend();
    }

    /// Filled rect with optional rounded corners and outline drawn inside the bounds.
    void rect(Rect r, Color fill, float radius = 0, Color stroke = Color.init, float strokeWidth = 0)
    {
        DrawCmd c = { op: Op.rect, r: r, radius: radius, fill: fill, stroke: stroke, width: strokeWidth };
        cmds ~= c;
    }

    /// Soft shadow under a rounded rect.
    void shadow(Rect r, float radius, float blur, Color c)
    {
        DrawCmd d = { op: Op.shadow, r: r, radius: radius, fill: c, width: blur };
        cmds ~= d;
    }

    /// Horizontal line one `thickness` tall below `y`, from `x0` to `x1`.
    void hline(float x0, float x1, float y, Color c, float thickness = 1)
    {
        rect(Rect(x0, y, x1 - x0, thickness), c);
    }

    /// Vertical line one `thickness` wide right of `x`, from `y0` to `y1`.
    void vline(float x, float y0, float y1, Color c, float thickness = 1)
    {
        rect(Rect(x, y0, thickness, y1 - y0), c);
    }

    /// Stroked open path.
    void polyline(Point[] points, float width, Color c)
    {
        DrawCmd d = { op: Op.polyline, points: points, width: width, stroke: c };
        cmds ~= d;
    }

    /// Filled convex path, clockwise on screen.
    void polygon(Point[] points, Color c)
    {
        DrawCmd d = { op: Op.polygon, points: points, fill: c };
        cmds ~= d;
    }

    /// Glyphs `[first, last)` of `run`, the first one at `origin` on the baseline.
    void text(ShapedRun run, Point origin, Color c, size_t first = 0, size_t last = size_t.max)
    {
        last = min(last, run.glyphs.length);
        float shift = first < run.glyphs.length ? run.pens[first] : 0;
        DrawCmd d = { op: Op.text, run: run, origin: origin, fill: c, first: first, last: last, shift: shift };
        cmds ~= d;
    }

    /// Intersects the clip with `r` until the matching `popClip`.
    void pushClip(Rect r)
    {
        DrawCmd d = { op: Op.pushClip, r: r };
        cmds ~= d;
    }

    /// Ends the innermost `pushClip`.
    void popClip()
    {
        DrawCmd d = { op: Op.popClip };
        cmds ~= d;
    }

    /// Fades shapes until the matching `popFade` to transparent over `left` inside the left edge of `r` and
    /// `right` inside its right edge. Child layers and custom draws do not fade.
    void pushFade(Rect r, float left, float right)
    {
        DrawCmd d = { op: Op.pushFade, r: r, width: left, right: right };
        cmds ~= d;
    }

    /// Ends the innermost `pushFade`.
    void popFade()
    {
        DrawCmd d = { op: Op.popFade };
        cmds ~= d;
    }

    /// Pixels `source` of `img`, or all of it if empty, stretched over `r` and multiplied by `tint`.
    void image(Rect r, Image img, Color tint = Color(255, 255, 255, 255), Rect source = Rect.init)
    {
        DrawCmd d = { op: Op.image, r: r, image: img, fill: tint, source: source };
        cmds ~= d;
    }

    /// Backend callback over `r`.
    void custom(Rect r, CustomDraw callback)
    {
        DrawCmd d = { op: Op.custom, r: r, callback: callback };
        cmds ~= d;
    }

    /// Child layer `l` with bounds `r`, composed in this place.
    void layer(Layer l, Rect r)
    {
        DrawCmd d = { op: Op.layer, r: r, layer: l };
        cmds ~= d;
    }

    /// Appends the commands of `other`.
    void append(const ref DrawList other)
    {
        foreach (ref const DrawCmd c; other.cmds)
        {
            cmds ~= cast(DrawCmd) c;
        }
    }
}

/// GPU vertex: physical pixel position, atlas texel coordinates, premultiplied color.
struct Vertex
{
    float x;   /// x in physical pixels
    float y;   /// y in physical pixels
    float u;   /// atlas texel x
    float v;   /// atlas texel y
    uint rgba; /// premultiplied color, 0xAABBGGRR
}

static assert(Vertex.sizeof == 20);

/// Clip rect in whole physical pixels, origin top left.
struct PixelRect
{
    int x; /// left
    int y; /// top
    int w; /// width
    int h; /// height

    /// True if the area is zero.
    bool empty() const
    {
        return w <= 0 || h <= 0;
    }

    /// Moved by `dx`, `dy`.
    PixelRect shift(int dx, int dy) const
    {
        return PixelRect(x + dx, y + dy, w, h);
    }

    /// True if `o` lies inside.
    bool contains(PixelRect o) const
    {
        return o.x >= x && o.y >= y && o.x + o.w <= x + w && o.y + o.h <= y + h;
    }
}

/// Indices `[start, start + count)` drawn under one clip, or a custom draw, or in a layer's mesh a child layer.
struct Batch
{
    PixelRect clip;       /// scissor rect the batch draws under
    uint start;           /// first index in the index buffer
    uint count;           /// index count
    FrameMesh source;     /// mesh that `start` and `count` index, null for the mesh holding the batch
    int dx;               /// shift of the `source` vertices, physical pixels
    int dy;               /// ditto
    CustomDraw callback;  /// custom draw instead of triangles, or null
    Rect area;            /// custom draw area, physical pixels
    Layer layer;          /// child layer instead of triangles, or null. Never in a frame's mesh
    Rect bounds;          /// child layer bounds when recorded, logical pixels
    Image image;          /// texture instead of the glyph atlas, or null
}

/// Tessellated frame or layer: one vertex and index buffer, split into batches. A composed frame has no
/// vertices of its own, its batches draw from the meshes of its layers, which renderers may keep on the GPU.
final class FrameMesh
{
    Vertex[] vertices; /// vertex buffer
    uint[] indices;    /// indices into `vertices`, three per triangle
    Batch[] batches;   /// batches in draw order
    int width;         /// framebuffer width in physical pixels
    int height;        /// framebuffer height in physical pixels
    bool missedGlyphs; /// atlas overflowed, some glyphs are missing
    uint revision;     /// bumped by `clear`, so renderers know when to upload the buffers again
    private Vertex[] vertexStore; /// memory behind `vertices` for the tessellator
    private uint[] indexStore;    /// memory behind `indices` for the tessellator

    /// Empties the buffers, keeping their memory.
    void clear()
    {
        ++revision;
        vertices.length = 0;
        vertices.assumeSafeAppend();
        indices.length = 0;
        indices.assumeSafeAppend();
        batches.length = 0;
        batches.assumeSafeAppend();
        missedGlyphs = false;
    }
}

/// Cached paint of one part of the window: commands, their mesh, and where they were recorded.
final class Layer
{
    DrawList list;      /// commands, child layers as `Op.layer`
    FrameMesh mesh;     /// tessellated `list`, not clipped to a framebuffer
    bool dirty = true;  /// `list` is stale
    bool complete;      /// the recording culled nothing, so it holds under any clip
    Point origin;       /// logical window position when recorded
    PixelRect scissor;  /// clip when recorded, in physical pixels
    float ppp = 0;      /// scale of `mesh`
    uint generation;    /// atlas generation of `mesh`
    void delegate(Layer, Point, Rect) record; /// paints into the layer at an origin, culling against a clip

    /// Creates a dirty layer painted by `record`, which fills `list` and sets `complete`.
    this(void delegate(Layer, Point, Rect) record)
    {
        this.record = record;
        mesh = new FrameMesh;
    }
}

/// Clip of a layer's mesh before composing, large enough to shift without overflow.
private enum PixelRect unclipped = PixelRect(-(1 << 28), -(1 << 28), 1 << 29, 1 << 29);

/// Converts commands to triangles.
struct Tessellator
{
    float ppp = 1;       /// physical pixels per logical pixel
    TextSystem text;     /// text system holding the glyph atlas, null for no text
    private FrameMesh m; /// output
    private Vertex[] vs; /// vertex memory of `m`, `nv` of them used
    private size_t nv;   /// vertices written
    private uint[] ix;   /// index memory of `m`, `ni` of them used
    private size_t ni;   /// indices written
    private PixelRect[] clips; /// clip stack
    private Point[] scratch;   /// path buffer
    private Point[] outer;     /// outer path of a ring
    private Point[] inner;     /// inner path of a ring
    private Fade[] fades;      /// fade stack
    private Image texture;     /// image the open batch samples, null for the atlas

    /// Tessellates `list` into `mesh` for a `width` by `height` framebuffer.
    void run(const ref DrawList list, FrameMesh mesh, int width, int height)
    {
        mesh.width = width;
        mesh.height = height;
        emit(list, mesh, PixelRect(0, 0, width, height));
    }

    /// Tessellates the commands of `l` into its mesh, unclipped. Child layers become batches of their own.
    void layer(Layer l)
    {
        emit(l.list, l.mesh, unclipped);
    }

    /// Tessellates `list` into `mesh` under `outer`.
    private void emit(const ref DrawList list, FrameMesh mesh, PixelRect outer)
    {
        m = mesh;
        m.clear();
        vs = m.vertexStore;
        ix = m.indexStore;
        nv = 0;
        ni = 0;
        scope (exit)
        {
            m.vertexStore = vs;
            m.indexStore = ix;
            m.vertices = vs[0 .. nv];
            m.indices = ix[0 .. ni];
            vs = null;
            ix = null;
        }
        clips.length = 0;
        clips.assumeSafeAppend();
        clips ~= outer;
        fades.length = 0;
        fades.assumeSafeAppend();
        texture = null;
        openBatch();
        foreach (ref const DrawCmd c; list.cmds)
        {
            uint i0 = cast(uint) ni;
            uint v0 = cast(uint) nv;
            final switch (c.op)
            {
            case Op.pushFade:
                fades ~= Fade(c.r.x * ppp, c.r.right * ppp, max(0f, c.width * ppp), max(0f, c.right * ppp));
                break;
            case Op.popFade:
                if (fades.length > 0)
                {
                    fades.length -= 1;
                    fades.assumeSafeAppend();
                }
                break;
            case Op.pushClip:
                PixelRect pr = toPixels(c.r);
                PixelRect top = clips[$ - 1];
                clips ~= intersectPixels(top, pr);
                openBatch();
                break;
            case Op.popClip:
                if (clips.length > 1)
                {
                    clips.length -= 1;
                    clips.assumeSafeAppend();
                }
                openBatch();
                break;
            case Op.rect:
                sample(null);
                rect(c);
                break;
            case Op.shadow:
                sample(null);
                shadow(c);
                break;
            case Op.polyline:
                sample(null);
                polyline(c.points, c.width * ppp, c.stroke);
                break;
            case Op.polygon:
                sample(null);
                polygon(c);
                break;
            case Op.text:
                sample(null);
                glyphs(c);
                break;
            case Op.image:
                image(c);
                break;
            case Op.custom:
                Rect area = Rect(round(c.r.x * ppp), round(c.r.y * ppp), round(c.r.w * ppp), round(c.r.h * ppp));
                closeBatch();
                Batch b;
                b.clip = clips[$ - 1];
                b.callback = cast(CustomDraw) c.callback;
                b.area = area;
                m.batches ~= b;
                openBatch();
                break;
            case Op.layer:
                closeBatch();
                Batch b;
                b.clip = clips[$ - 1];
                b.layer = cast(Layer) c.layer;
                b.bounds = c.r;
                m.batches ~= b;
                openBatch();
                break;
            }
            if (fades.length > 0 && ni > i0)
            {
                applyFades(i0, v0);
            }
        }
        closeBatch();
        size_t kept;
        foreach (ref Batch b; m.batches)
        {
            if ((b.count > 0 || b.callback !is null || b.layer !is null) && b.clip.w > 0 && b.clip.h > 0)
            {
                m.batches[kept++] = b;
            }
        }
        m.batches.length = kept;
    }

    /// Appends a vertex and returns its index.
    private uint vertex(float x, float y, float u, float v, uint rgba)
    {
        if (nv == vs.length)
        {
            vs = grown(vs, nv);
        }
        vs[nv] = Vertex(x, y, u, v, rgba);
        return cast(uint) nv++;
    }

    /// Appends triangle `a`, `b`, `c`.
    private void triangle(uint a, uint b, uint c)
    {
        if (ni + 3 > ix.length)
        {
            ix = grown(ix, ni);
        }
        ix[ni] = a;
        ix[ni + 1] = b;
        ix[ni + 2] = c;
        ni += 3;
    }

    /// Appends quad `a`, `b`, `c`, `d` as two triangles sharing `a` and `c`.
    private void quad(uint a, uint b, uint c, uint d)
    {
        triangle(a, b, c);
        triangle(a, c, d);
    }

    /// Starts a batch under the current clip, reusing the last one if it is still empty.
    private void openBatch()
    {
        uint at = cast(uint) ni;
        if (m.batches.length > 0 && m.batches[$ - 1].callback is null && m.batches[$ - 1].layer is null
            && m.batches[$ - 1].count == 0 && m.batches[$ - 1].start == at)
        {
            m.batches[$ - 1].clip = clips[$ - 1];
            m.batches[$ - 1].image = texture;
            return;
        }
        closeBatch();
        Batch b = Batch(clips[$ - 1], at, 0);
        b.image = texture;
        m.batches ~= b;
    }

    /// Makes later triangles sample `img`, or the atlas if null, starting a batch if that changes.
    private void sample(const Image img)
    {
        if (texture !is img)
        {
            texture = cast(Image) img;
            openBatch();
        }
    }

    /// Splits the triangles from index `i0` at every fade edge, then scales the alpha of vertices from `v0`.
    private void applyFades(uint i0, uint v0)
    {
        foreach (ref const Fade f; fades)
        {
            if (f.left > 0)
            {
                splitAt(i0, f.x0);
                splitAt(i0, f.x0 + f.left);
            }
            if (f.right > 0)
            {
                splitAt(i0, f.x1 - f.right);
                splitAt(i0, f.x1);
            }
        }
        foreach (ref Vertex v; vs[v0 .. nv])
        {
            float k = 1;
            foreach (ref const Fade f; fades)
            {
                k *= f.at(v.x);
            }
            if (k < 1)
            {
                v.rgba = scaled(v.rgba, k);
            }
        }
    }

    /// Splits the triangles from index `i0` that cross the vertical line at `x`, so none spans it.
    private void splitAt(uint i0, float x)
    {
        enum float eps = 1e-3f;
        size_t end = ni;
        for (size_t t = i0; t + 2 < end; t += 3)
        {
            uint[3] tri = ix[t .. t + 3];
            float[3] d;
            int below;
            int above;
            foreach (size_t k; 0 .. 3)
            {
                d[k] = vs[tri[k]].x - x;
                if (d[k] < -eps)
                {
                    ++below;
                }
                else if (d[k] > eps)
                {
                    ++above;
                }
            }
            if (below == 0 || above == 0)
            {
                continue;
            }
            // first: the vertex alone on its side, or on the line
            size_t a = 0;
            foreach (size_t k; 0 .. 3)
            {
                bool on = d[k] >= -eps && d[k] <= eps;
                bool alone = (d[k] < -eps && below == 1) || (d[k] > eps && above == 1);
                if (below + above == 2 ? on : alone)
                {
                    a = k;
                }
            }
            uint ia = tri[a];
            uint ib = tri[(a + 1) % 3];
            uint ic = tri[(a + 2) % 3];
            if (below + above == 2)
            {
                uint p = cut(ib, ic, x);
                ix[t + 2] = p;
                ix[t] = ia;
                ix[t + 1] = ib;
                triangle(ia, p, ic);
            }
            else
            {
                uint p = cut(ia, ib, x);
                uint q = cut(ia, ic, x);
                ix[t] = ia;
                ix[t + 1] = p;
                ix[t + 2] = q;
                triangle(p, ib, ic);
                triangle(p, ic, q);
            }
        }
    }

    /// Index of a new vertex where the edge from vertex `a` to vertex `b` crosses the vertical line at `x`.
    private uint cut(uint a, uint b, float x)
    {
        Vertex va = vs[a];
        Vertex vb = vs[b];
        float t = (x - va.x) / (vb.x - va.x);
        uint rgba;
        static foreach (int sh; [0, 8, 16, 24])
        {{
            float ca = (va.rgba >> sh) & 0xff;
            float cb = (vb.rgba >> sh) & 0xff;
            rgba |= (cast(uint) round(ca + (cb - ca) * t) & 0xff) << sh;
        }}
        return vertex(x, va.y + (vb.y - va.y) * t, va.u + (vb.u - va.u) * t, va.v + (vb.v - va.v) * t, rgba);
    }

    /// Sets the index count of the open batch.
    private void closeBatch()
    {
        if (m.batches.length > 0 && m.batches[$ - 1].callback is null && m.batches[$ - 1].layer is null)
        {
            m.batches[$ - 1].count = cast(uint) ni - m.batches[$ - 1].start;
        }
    }

    /// Logical rect to whole physical pixels.
    private PixelRect toPixels(Rect r)
    {
        int x0 = cast(int) floor(r.x * ppp + 0.001f);
        int y0 = cast(int) floor(r.y * ppp + 0.001f);
        int x1 = cast(int) ceil((r.x + r.w) * ppp - 0.001f);
        int y1 = cast(int) ceil((r.y + r.h) * ppp - 0.001f);
        return PixelRect(x0, y0, max(0, x1 - x0), max(0, y1 - y0));
    }

    /// Logical rect with edges snapped to physical pixels.
    private Rect snapRect(Rect r)
    {
        float x0 = round(r.x * ppp);
        float y0 = round(r.y * ppp);
        float x1 = round((r.x + r.w) * ppp);
        float y1 = round((r.y + r.h) * ppp);
        if (r.w > 0 && x1 == x0)
        {
            x1 = x0 + 1;
        }
        if (r.h > 0 && y1 == y0)
        {
            y1 = y0 + 1;
        }
        return Rect(x0, y0, x1 - x0, y1 - y0);
    }

    /// Fill and inner stroke of a rect command.
    private void rect(const ref DrawCmd c)
    {
        Rect p = snapRect(c.r);
        if (p.empty)
        {
            return;
        }
        float radius = min(c.radius * ppp, min(p.w, p.h) / 2);
        if (c.fill.a > 0)
        {
            roundedPath(p, radius, segmentsFor(radius));
            fillConvex(scratch, c.fill.premul, 1);
        }
        if (c.stroke.a > 0 && c.width > 0)
        {
            float w = max(1f, round(c.width * ppp));
            ring(p, radius, w, c.stroke.premul);
        }
    }

    /// Soft shadow: the rect with a fade as wide as the blur.
    private void shadow(const ref DrawCmd c)
    {
        Rect p = snapRect(c.r);
        float radius = min(c.radius * ppp, min(p.w, p.h) / 2);
        float blur = max(1f, c.width * ppp);
        roundedPath(p, radius, segmentsFor(radius + blur));
        fillConvex(scratch, c.fill.premul, blur);
    }

    /// Filled convex polygon in logical points.
    private void polygon(const ref DrawCmd c)
    {
        scratch.length = 0;
        scratch.assumeSafeAppend();
        foreach (Point q; c.points)
        {
            scratch ~= Point(q.x * ppp, q.y * ppp);
        }
        fillConvex(scratch, c.fill.premul, 1);
    }

    /// Corner segments for a physical radius.
    private static int segmentsFor(float radius)
    {
        return radius <= 0 ? 0 : clamp(cast(int) ceil(radius / 1.5f), 2, 32);
    }

    /// Writes the clockwise outline of `r` with rounded corners into `scratch`.
    /// Every corner has `segments + 1` points, or one when `segments` is zero.
    private void roundedPath(Rect r, float radius, int segments)
    {
        scratch.length = 0;
        scratch.assumeSafeAppend();
        roundedPathInto(scratch, r, radius, segments);
    }

    /// Fills a convex clockwise path with a `feather` pixel fade to transparent.
    private void fillConvex(const Point[] path, uint color, float feather)
    {
        size_t n = path.length;
        if (n < 3)
        {
            return;
        }
        uint base = cast(uint) nv;
        float w = GlyphAtlas.whiteUV;
        float h = feather / 2;
        foreach (size_t i; 0 .. n)
        {
            Point miter = miterAt(path, i, true);
            Point cur = path[i];
            vertex(cur.x - miter.x * h, cur.y - miter.y * h, w, w, color);
            vertex(cur.x + miter.x * h, cur.y + miter.y * h, w, w, 0);
        }
        foreach (uint i; 1 .. cast(uint) n - 1)
        {
            triangle(base, base + 2 * i, base + 2 * (i + 1));
        }
        foreach (uint i; 0 .. cast(uint) n)
        {
            uint j = (i + 1) % cast(uint) n;
            uint ii = base + 2 * i;
            uint jj = base + 2 * j;
            quad(ii, ii + 1, jj + 1, jj);
        }
    }

    /// Outline of `width` physical pixels inside rounded rect `r`, feathered on both sides.
    private void ring(Rect r, float radius, float width, uint color)
    {
        int seg = segmentsFor(radius);
        outer.length = 0;
        outer.assumeSafeAppend();
        roundedPathInto(outer, r, radius, seg);
        inner.length = 0;
        inner.assumeSafeAppend();
        roundedPathInto(inner, r.inset(width), max(0f, radius - width), seg);
        size_t n = outer.length;
        if (n != inner.length || n < 3)
        {
            return;
        }
        uint base = cast(uint) nv;
        float uv = GlyphAtlas.whiteUV;
        foreach (size_t i; 0 .. n)
        {
            Point no = miterAt(outer, i, true);
            Point ni = miterAt(inner, i, true);
            Point o = outer[i];
            Point q = inner[i];
            vertex(o.x + no.x * 0.5f, o.y + no.y * 0.5f, uv, uv, 0);
            vertex(o.x - no.x * 0.5f, o.y - no.y * 0.5f, uv, uv, color);
            vertex(q.x + ni.x * 0.5f, q.y + ni.y * 0.5f, uv, uv, color);
            vertex(q.x - ni.x * 0.5f, q.y - ni.y * 0.5f, uv, uv, 0);
        }
        foreach (uint i; 0 .. cast(uint) n)
        {
            uint j = (i + 1) % cast(uint) n;
            foreach (uint k; 0 .. 3)
            {
                uint a = base + 4 * i + k;
                uint b = base + 4 * j + k;
                quad(a, a + 1, b + 1, b);
            }
        }
    }

    /// Stroked open path, `width` physical pixels, feathered on both sides.
    private void polyline(const Point[] logical, float width, Color c)
    {
        size_t n = logical.length;
        if (n < 2)
        {
            return;
        }
        scratch.length = 0;
        scratch.assumeSafeAppend();
        foreach (Point q; logical)
        {
            scratch ~= Point(q.x * ppp, q.y * ppp);
        }
        float core = max(0f, width / 2 - 0.5f);
        float edge = max(width, 1f) / 2 + 0.5f;
        uint color = (width < 1 ? c.fade(width) : c).premul;
        uint base = cast(uint) nv;
        float uv = GlyphAtlas.whiteUV;
        foreach (size_t i; 0 .. n)
        {
            Point nm = miterAt(scratch, i, false);
            Point p = scratch[i];
            vertex(p.x + nm.x * edge, p.y + nm.y * edge, uv, uv, 0);
            vertex(p.x + nm.x * core, p.y + nm.y * core, uv, uv, color);
            vertex(p.x - nm.x * core, p.y - nm.y * core, uv, uv, color);
            vertex(p.x - nm.x * edge, p.y - nm.y * edge, uv, uv, 0);
        }
        foreach (uint i; 0 .. cast(uint) n - 1)
        {
            foreach (uint k; 0 .. 3)
            {
                uint a = base + 4 * i + k;
                uint b = base + 4 * (i + 1) + k;
                quad(a, a + 1, b + 1, b);
            }
        }
    }

    /// Quad of an image command, edges snapped to pixels.
    private void image(const ref DrawCmd c)
    {
        if (c.image is null || c.image.empty)
        {
            return;
        }
        Rect p = snapRect(c.r);
        Rect s = c.source.empty ? Rect(0, 0, c.image.width, c.image.height) : c.source;
        if (p.empty || c.fill.a == 0)
        {
            return;
        }
        sample(c.image);
        uint color = c.fill.premul;
        uint b = vertex(p.x, p.y, s.x, s.y, color);
        vertex(p.right, p.y, s.right, s.y, color);
        vertex(p.right, p.bottom, s.right, s.bottom, color);
        vertex(p.x, p.bottom, s.x, s.bottom, color);
        quad(b, b + 1, b + 2, b + 3);
    }

    /// Glyph quads of a text command.
    private void glyphs(const ref DrawCmd c)
    {
        if (text is null || c.run is null)
        {
            return;
        }
        const ShapedRun run = c.run;
        SizedFont f = cast(SizedFont) run.font;
        bool mixed = run.faces.length > 0;
        float ox = c.origin.x * ppp;
        float baseline = round(c.origin.y * ppp);
        uint color = c.fill.premul;
        uint white = (color >> 24) * 0x01010101u;
        foreach (size_t i; c.first .. c.last)
        {
            int pen;
            ubyte bin = subpixel(ox + run.xs[i] - c.shift, pen);
            GlyphSlot* s = text.glyph(mixed ? cast(SizedFont) run.faces[i] : f, run.glyphs[i], bin);
            if (s is null)
            {
                m.missedGlyphs = true;
                continue;
            }
            if (s.w == 0)
            {
                continue;
            }
            float x0 = pen + s.left;
            float y0 = baseline + round(run.ys[i]) - s.top;
            float x1 = x0 + s.w;
            float y1 = y0 + s.h;
            uint tint = s.color ? white : color;
            uint b = vertex(x0, y0, s.x, s.y, tint);
            vertex(x1, y0, s.x + s.w, s.y, tint);
            vertex(x1, y1, s.x + s.w, s.y + s.h, tint);
            vertex(x0, y1, s.x, s.y + s.h, tint);
            quad(b, b + 1, b + 2, b + 3);
        }
    }
}

/// Copy of `a[0 .. used]` in new memory twice as large, at least 256 elements.
private T[] grown(T)(T[] a, size_t used)
{
    import std.array : uninitializedArray;

    T[] n = uninitializedArray!(T[])(max(256, a.length * 2));
    n[0 .. used] = a[0 .. used];
    return n;
}

/// Cosine and sine of every corner point for `segments` steps per quarter turn, clockwise from the top left
/// corner. Computed once per segment count.
private const(double[2])[] cornerTurns(int segments)
{
    static double[2][][33] cache;
    if (cache[segments].length == 0)
    {
        double[2][] t;
        foreach (int corner; 0 .. 4)
        {
            double start = PI + corner * PI / 2;
            foreach (int s; 0 .. segments + 1)
            {
                double a = start + s * (PI / 2) / segments;
                t ~= [cos(a), sin(a)];
            }
        }
        cache[segments] = t;
    }
    return cache[segments];
}

/// Appends the clockwise outline of `r` with rounded corners to `path`.
void roundedPathInto(ref Point[] path, Rect r, float radius, int segments)
{
    if (segments == 0)
    {
        path ~= Point(r.x, r.y);
        path ~= Point(r.x + r.w, r.y);
        path ~= Point(r.x + r.w, r.y + r.h);
        path ~= Point(r.x, r.y + r.h);
        return;
    }
    Point[4] centers = [
        Point(r.x + radius, r.y + radius),
        Point(r.x + r.w - radius, r.y + radius),
        Point(r.x + r.w - radius, r.y + r.h - radius),
        Point(r.x + radius, r.y + r.h - radius),
    ];
    const(double[2])[] turns = cornerTurns(segments);
    size_t at;
    foreach (size_t corner, Point c; centers)
    {
        foreach (int s; 0 .. segments + 1)
        {
            path ~= Point(c.x + radius * turns[at][0], c.y + radius * turns[at][1]);
            ++at;
        }
    }
}

/// Outward miter at point `i` of `path`, scaled so offsets keep edge distance. `closed` wraps the ends.
/// Neighbors at the same position are skipped, so duplicate points share one miter and the offset
/// contour never folds back.
private Point miterAt(const Point[] path, size_t i, bool closed)
{
    size_t n = path.length;
    Point cur = path[i];
    Point n0;
    Point n1;
    bool has0;
    bool has1;
    size_t k = i;
    foreach (size_t step; 1 .. n)
    {
        if (k == 0 && closed == false)
        {
            break;
        }
        k = (k + n - 1) % n;
        if (normal(path[k], cur, n0))
        {
            has0 = true;
            break;
        }
    }
    k = i;
    foreach (size_t step; 1 .. n)
    {
        if (k + 1 == n && closed == false)
        {
            break;
        }
        k = (k + 1) % n;
        if (normal(cur, path[k], n1))
        {
            has1 = true;
            break;
        }
    }
    if (has0 == false && has1 == false)
    {
        return Point(0, 0);
    }
    if (has0 == false)
    {
        return n1;
    }
    if (has1 == false)
    {
        return n0;
    }
    Point avg = Point((n0.x + n1.x) / 2, (n0.y + n1.y) / 2);
    float lenSq = avg.x * avg.x + avg.y * avg.y;
    if (lenSq < 0.05f)
    {
        return n1;
    }
    return Point(avg.x / lenSq, avg.y / lenSq);
}

/// Unit normal of edge `a` to `b`, pointing out of a clockwise path. False for a zero-length edge.
private bool normal(Point a, Point b, out Point n)
{
    float dx = b.x - a.x;
    float dy = b.y - a.y;
    float len = sqrt(dx * dx + dy * dy);
    if (len < 1e-4f)
    {
        return false;
    }
    n = Point(dy / len, -dx / len);
    return true;
}

/// Intersection of two pixel rects.
PixelRect intersectPixels(PixelRect a, PixelRect b)
{
    int x0 = max(a.x, b.x);
    int y0 = max(a.y, b.y);
    int x1 = min(a.x + a.w, b.x + b.w);
    int y1 = min(a.y + a.h, b.y + b.h);
    return PixelRect(x0, y0, max(0, x1 - x0), max(0, y1 - y0));
}

/// Builds frames from layers: records and tessellates stale layers, then adds batches that draw from each
/// layer's mesh, shifted to where the layer is now. Child layers are culled here, as their parents record
/// them whatever the clip.
struct Compositor
{
    Tessellator tess;      /// tessellator, holding the scale and the glyph atlas
    bool cache = true;     /// false records every layer every frame, for comparisons
    int recorded;          /// layers recorded in the last compose
    int reused;            /// layers reused unchanged in the last compose
    size_t commands;       /// commands recorded in the last compose
    Duration painting;     /// recording time of the last compose
    Duration tessellating; /// tessellation time of the last compose
    size_t vertices;       /// vertices of the layers drawn in the last compose
    size_t meshBytes;      /// vertex and index bytes of those layers

    /// Composes `root` and the layers it refers to into `m` for a `width` by `height` framebuffer, with the
    /// node of `root` at logical `origin`.
    void compose(Layer root, FrameMesh m, int width, int height, Point origin = Point(0, 0))
    {
        m.clear();
        m.width = width;
        m.height = height;
        recorded = 0;
        reused = 0;
        commands = 0;
        vertices = 0;
        meshBytes = 0;
        painting = Duration.zero;
        tessellating = Duration.zero;
        place(root, origin, PixelRect(0, 0, width, height), m);
    }

    /// Appends layer `l`, now at logical `origin` under `scissor`, after recording it if stale or moved by a
    /// fraction of a pixel. A recording that culled something holds only while the clip stays inside its own.
    private void place(Layer l, Point origin, PixelRect scissor, FrameMesh m)
    {
        float ppp = tess.ppp;
        uint generation = tess.text is null ? 0 : tess.text.atlas.generation;
        Point d = origin - l.origin;
        int dx = cast(int) round(d.x * ppp);
        int dy = cast(int) round(d.y * ppp);
        bool whole = abs(d.x * ppp - dx) < 1e-3f && abs(d.y * ppp - dy) < 1e-3f;
        bool fresh = cache && l.dirty == false && l.ppp == ppp && l.generation == generation && whole
            && (l.complete || l.scissor.contains(scissor.shift(-dx, -dy)));
        if (fresh == false)
        {
            MonoTime t0 = MonoTime.currTime;
            l.dirty = false;
            l.record(l, origin, Rect(scissor.x / ppp, scissor.y / ppp, scissor.w / ppp, scissor.h / ppp));
            MonoTime t1 = MonoTime.currTime;
            tess.layer(l);
            painting += t1 - t0;
            tessellating += MonoTime.currTime - t1;
            l.origin = origin;
            l.scissor = scissor;
            l.ppp = ppp;
            l.generation = generation;
            if (l.mesh.missedGlyphs)
            {
                l.dirty = true;
                m.missedGlyphs = true;
            }
            ++recorded;
            commands += l.list.cmds.length;
            d = Point(0, 0);
            dx = 0;
            dy = 0;
        }
        else
        {
            ++reused;
        }
        bool drawn;
        foreach (ref const Batch b; l.mesh.batches)
        {
            PixelRect clip = intersectPixels(b.clip.shift(dx, dy), scissor);
            if (clip.empty)
            {
                continue;
            }
            if (b.layer !is null)
            {
                Rect r = b.bounds.translate(d);
                if (r.empty == false && intersectPixels(tess.toPixels(r), clip).empty)
                {
                    continue;
                }
                place(cast(Layer) b.layer, r.pos, clip, m);
                continue;
            }
            if (b.callback !is null)
            {
                Batch c;
                c.clip = clip;
                c.callback = cast(CustomDraw) b.callback;
                c.area = b.area.translate(Point(dx, dy));
                m.batches ~= c;
                continue;
            }
            if (drawn == false)
            {
                drawn = true;
                vertices += l.mesh.vertices.length;
                meshBytes += l.mesh.vertices.length * Vertex.sizeof + l.mesh.indices.length * uint.sizeof;
            }
            if (m.batches.length > 0)
            {
                Batch* p = &m.batches[$ - 1];
                if (p.callback is null && p.source is l.mesh && p.dx == dx && p.dy == dy && p.clip == clip
                    && p.image is b.image && p.start + p.count == b.start)
                {
                    p.count += b.count;
                    continue;
                }
            }
            Batch nb = Batch(clip, b.start, b.count, l.mesh, dx, dy);
            nb.image = cast(Image) b.image;
            m.batches ~= nb;
        }
    }
}

/// Fade of the tessellator, physical pixels.
private struct Fade
{
    float x0;    /// left edge
    float x1;    /// right edge
    float left;  /// fade width inside the left edge, 0 for none
    float right; /// fade width inside the right edge, 0 for none

    /// Alpha factor at `x`, 0 at an edge with a fade and 1 past the fade.
    float at(float x) const
    {
        float k = 1;
        if (left > 0)
        {
            k = min(k, clamp((x - x0) / left, 0f, 1f));
        }
        if (right > 0)
        {
            k = min(k, clamp((x1 - x) / right, 0f, 1f));
        }
        return k;
    }
}

/// Premultiplied `rgba` with every channel times `k`.
private uint scaled(uint rgba, float k)
{
    uint o;
    static foreach (int sh; [0, 8, 16, 24])
    {
        o |= (cast(uint) round(((rgba >> sh) & 0xff) * k) & 0xff) << sh;
    }
    return o;
}

/// Sum of triangle areas where every vertex is opaque.
version (unittest) private double opaqueArea(const FrameMesh m)
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

// A square snaps to pixels and keeps an opaque core half a pixel inside each edge.
unittest
{
    DrawList l;
    l.rect(Rect(10.2, 10, 20, 20), Color(255, 255, 255, 255));
    FrameMesh m = new FrameMesh;
    Tessellator t;
    t.run(l, m, 100, 100);
    assert(m.vertices.length == 8);
    assert(m.vertices[0].x == 10.5 && m.vertices[1].x == 9.5, "snapped edge at 10");
    assert(opaqueArea(m) == 19.0 * 19.0);
    assert(m.batches.length == 1 && m.batches[0].count == 3 * (2 + 8));
}

// Rounded corners at 2x: the opaque core matches the shape shrunk by half a pixel.
unittest
{
    DrawList l;
    l.rect(Rect(0, 0, 50, 30), Color(40, 40, 40, 255), 6);
    FrameMesh m = new FrameMesh;
    Tessellator t;
    t.ppp = 2;
    t.run(l, m, 200, 200);
    double full = 100.0 * 60 - (4 - PI) * 12 * 12;
    double area = opaqueArea(m);
    assert(area > full - 170 && area < full - 150, "about a half pixel ring removed");
}

// A one pixel border: zero-width opaque core on pixel centers, so the line is one pixel exactly.
unittest
{
    DrawList l;
    l.rect(Rect(0, 0, 10, 10), Color.init, 0, Color(255, 0, 0, 255), 1);
    FrameMesh m = new FrameMesh;
    Tessellator t;
    t.run(l, m, 100, 100);
    assert(m.vertices.length == 16);
    assert(m.vertices[0].x == -0.5 && m.vertices[1].x == 0.5 && m.vertices[2].x == 0.5 && m.vertices[3].x == 1.5);
}

// Clips split batches, nested clips intersect, and custom draws get their own batch.
unittest
{
    DrawList l;
    l.rect(Rect(0, 0, 10, 10), Color(1, 1, 1, 255));
    l.pushClip(Rect(5, 5, 50, 50));
    l.pushClip(Rect(0, 0, 20.5, 20));
    l.rect(Rect(0, 0, 10, 10), Color(1, 1, 1, 255));
    l.popClip();
    l.custom(Rect(10, 10, 5, 5), (Rect a, Rect c, Size f) {});
    l.popClip();
    l.pushClip(Rect(0, 0, 0, 0));
    l.rect(Rect(0, 0, 10, 10), Color(1, 1, 1, 255));
    l.popClip();
    FrameMesh m = new FrameMesh;
    Tessellator t;
    t.ppp = 2;
    t.run(l, m, 200, 200);
    assert(m.batches.length == 3, "the empty clip is dropped");
    assert(m.batches[0].clip == PixelRect(0, 0, 200, 200));
    assert(m.batches[1].clip == PixelRect(10, 10, 31, 30), "rounded outward at 2x");
    assert(m.batches[2].callback !is null && m.batches[2].area == Rect(20, 20, 10, 10));
    assert(m.batches[2].clip == PixelRect(10, 10, 100, 100));
}

// Text: one quad per inked glyph at whole pixels, spaces skipped, a glyph range drawn from its own start.
unittest
{
    TextSystem ts = testText();
    scope (exit)
    {
        ts.dispose();
    }
    ShapedRun r = ts.shape(FontKind.mono, 13, "ab cd");
    DrawList l;
    l.text(r, Point(10, 20), Color(255, 255, 255, 255));
    l.text(r, Point(10, 40), Color(255, 255, 255, 255), 3, 5);
    FrameMesh m = new FrameMesh;
    Tessellator t;
    t.text = ts;
    t.run(l, m, 200, 200);
    assert(m.vertices.length == 4 * 6, "four inked glyphs, then two");
    float firstC = m.vertices[4 * 2].x;
    float again = m.vertices[4 * 4].x;
    assert(again < firstC, "the range starts at its own origin");
    foreach (ref const Vertex v; m.vertices)
    {
        assert(v.x == round(v.x) && v.y == round(v.y));
    }
}

// A pill (radius half the width) has duplicate path points where arcs meet. They share one inner
// vertex, so no fill triangle is wound backwards and nothing is blended twice.
unittest
{
    DrawList l;
    l.rect(Rect(0, 0, 8, 100), Color(255, 255, 255, 34), 4);
    FrameMesh m = new FrameMesh;
    Tessellator t;
    t.run(l, m, 100, 100);
    double signed = 0;
    for (size_t k = 0; k + 2 < 3 * (m.vertices.length / 2 - 2) + 1; k += 3)
    {
        const Vertex a = m.vertices[m.indices[k]];
        const Vertex b = m.vertices[m.indices[k + 1]];
        const Vertex c = m.vertices[m.indices[k + 2]];
        double cross = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y);
        assert(cross >= -1e-4, "fan triangle wound backwards");
        signed += cross;
    }
    assert(signed > 0);
}

// Images get batches of their own with texel coordinates from the source rect, the same image keeps
// its batch, shapes go back to the atlas, and an empty image changes nothing.
unittest
{
    Image a = new Image(4, 2);
    Image b = new Image(2, 2);
    Color white = Color(255, 255, 255, 255);
    DrawList l;
    l.rect(Rect(0, 0, 10, 10), white);
    l.image(Rect(0, 0, 8, 4), a);
    l.image(Rect(10, 0, 8, 4), a, white, Rect(1, 0, 2, 2));
    l.image(Rect(20, 0, 4, 4), b);
    l.rect(Rect(0, 20, 10, 10), white);
    l.image(Rect(0, 0, 0, 4), b);
    l.rect(Rect(0, 40, 10, 10), white);
    FrameMesh m = new FrameMesh;
    Tessellator t;
    t.ppp = 2;
    t.run(l, m, 100, 100);
    assert(m.batches.length == 4);
    assert(m.batches[0].image is null && m.batches[1].image is a && m.batches[1].count == 12);
    assert(m.batches[2].image is b && m.batches[3].image is null);
    assert(m.vertices[12] == Vertex(20, 0, 1, 0, white.premul));
    assert(m.vertices[14] == Vertex(36, 8, 3, 2, white.premul));
}

// Composing keeps the image of every batch, so a layer's atlas and image batches stay apart.
unittest
{
    Image img = new Image(2, 2);
    Layer root = new Layer((Layer l, Point at, Rect clip) {
        l.list.clear();
        l.list.rect(Rect(0, 0, 10, 10), Color(255, 255, 255, 255));
        l.list.image(Rect(10, 0, 10, 10), img);
        l.list.rect(Rect(20, 0, 10, 10), Color(255, 255, 255, 255));
        l.complete = true;
    });
    FrameMesh m = new FrameMesh;
    Compositor c;
    c.compose(root, m, 100, 100);
    assert(m.batches.length == 3);
    assert(m.batches[0].image is null && m.batches[1].image is img && m.batches[2].image is null);
}

version (unittest)
{
    /// Triangle with the clip it is drawn under, for comparing meshes.
    struct Tri
    {
        PixelRect clip; /// scissor rect the batch draws under
        Vertex[3] v;    /// corners
    }

    /// Every triangle of `m` in draw order, with its clip. Custom draws are skipped.
    Tri[] triangles(const FrameMesh m)
    {
        Tri[] ts;
        foreach (ref const Batch b; m.batches)
        {
            const FrameMesh s = b.source is null ? m : b.source;
            for (uint i = b.start; i + 3 <= b.start + b.count; i += 3)
            {
                Vertex[3] v = [s.vertices[s.indices[i]], s.vertices[s.indices[i + 1]], s.vertices[s.indices[i + 2]]];
                foreach (ref Vertex c; v)
                {
                    c.x += b.dx;
                    c.y += b.dy;
                }
                ts ~= Tri(b.clip, v);
            }
        }
        return ts;
    }
}

// Color glyphs keep their texels: their quads take the text alpha only, other glyphs the text color.
unittest
{
    TextSystem ts = testEmojiText();
    scope (exit)
    {
        ts.dispose();
    }
    DrawList l;
    l.text(ts.shape(FontKind.ui, 14, "a😀"), Point(10, 20), Color(255, 0, 0, 128));
    FrameMesh m = new FrameMesh;
    Tessellator t;
    t.text = ts;
    t.run(l, m, 200, 200);
    assert(m.vertices.length == 8);
    assert(m.vertices[0].rgba == 0x80000080 && m.vertices[4].rgba == 0x80808080);
}
