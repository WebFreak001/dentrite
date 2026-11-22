/// Text rendering: font files, shaping with HarfBuzz, rasterizing with FreeType into one glyph atlas.
///
/// Characters the slot's font lacks come from the first fallback file that has them, as runs shaped apart.
/// NOTE: fallback glyphs use the slot font's line metrics, and color glyphs such as emoji draw nothing.
///
/// Shaping runs at the physical pixel size, so runs and metrics are in physical
/// pixels and callers divide by `ppp` for layout. Glyphs are rasterized with light
/// (vertical only) hinting at one of four horizontal subpixel offsets. A scale
/// change drops every cache.
module dentrite.text;

import core.stdc.config : c_long;
import dentrite.c.freetype;
import dentrite.c.harfbuzz;
import std.algorithm.comparison : max, min;
import std.exception : enforce;
import std.format : format;
import std.math : ceil, floor, pow, round;
import std.string : toStringz;
import std.typecons : Yes;
import std.uni : isMark;
import std.utf : decode;

/// Font slots that styles name.
enum FontKind : ubyte
{
    ui,       /// proportional body text
    uiStrong, /// proportional, heavier, for headers and buttons
    mono,     /// fixed pitch, for addresses, bytes and code
}

/// Horizontal subpixel positions per pixel.
enum int subpixelBins = 4;

/// One font face at one physical pixel size.
final class SizedFont
{
    uint id;        /// index in `TextSystem.sized`, part of glyph keys
    size_t file;    /// font file index: a `FontKind` slot, or a fallback numbered after the slots
    float px;       /// physical pixel size
    FT_Face face;   /// FreeType face, size set to `px`
    hb_font_t* hb;  /// HarfBuzz font over `face`
    float ascent;   /// physical pixels above the baseline
    float descent;  /// physical pixels below the baseline, positive
    float lineGap;  /// extra physical pixels between lines
}

/// Shaped text in physical pixels from the run's pen start.
final class ShapedRun
{
    string text;      /// source text, UTF-8
    SizedFont font;   /// slot font it was shaped with
    SizedFont[] faces; /// font of each glyph when fallbacks were used, else empty
    uint[] glyphs;    /// glyph indices
    float[] pens;     /// pen x before each glyph
    float[] xs;       /// draw x of each glyph, the pen plus its x offset
    float[] ys;       /// y offset of each glyph, down positive
    uint[] clusters;  /// byte offset in `text` of each glyph's cluster
    float width = 0;  /// total advance in physical pixels

    /// Pen x before the character at byte `index`, for carets. `text.length` gives the end.
    float caretX(size_t index) const
    {
        foreach (size_t i, uint c; clusters)
        {
            if (c >= index)
            {
                return pens[i];
            }
        }
        return width;
    }

    /// Byte offset of the caret position nearest to physical `x`.
    size_t indexAt(float x) const
    {
        if (glyphs.length == 0 || x <= 0)
        {
            return 0;
        }
        foreach (size_t i; 0 .. glyphs.length)
        {
            float start = pens[i];
            float end = i + 1 < glyphs.length ? pens[i + 1] : width;
            if (x < (start + end) / 2)
            {
                return clusters[i];
            }
        }
        return text.length;
    }
}

/// One line of wrapped text: glyphs `[first, last)` of a run.
struct Line
{
    size_t first;  /// index of the first glyph in the run
    size_t last;   /// index one past the last glyph in the run
    float x0 = 0;  /// run x of the first glyph, subtract to start the line at zero
    float width = 0; /// advance of the line without trailing spaces
}

/// Lines of `run` no wider than `maxWidth` physical pixels, broken after spaces.
/// A word longer than the width gets a line of its own and overflows.
Line[] wrap(const ShapedRun run, float maxWidth)
{
    Line[] lines;
    size_t n = run.glyphs.length;
    if (n == 0)
    {
        return [Line(0, 0, 0, 0)];
    }

    /// Run x where glyph `i` starts, or the run end.
    float startOf(size_t i)
    {
        return i < n ? run.pens[i] : run.width;
    }

    /// True if glyph `i` is a space.
    bool space(size_t i)
    {
        uint c = run.clusters[i];
        return c < run.text.length && (run.text[c] == ' ' || run.text[c] == '\t');
    }

    size_t first;
    size_t lastBreak = size_t.max;
    foreach (size_t i; 0 .. n)
    {
        if (space(i))
        {
            lastBreak = i;
        }
        float right = startOf(i + 1) - startOf(first);
        if (right > maxWidth && i > first && lastBreak != size_t.max && lastBreak >= first)
        {
            size_t end = lastBreak;
            lines ~= Line(first, end, startOf(first), startOf(end) - startOf(first));
            first = end + 1;
            lastBreak = size_t.max;
        }
    }
    size_t end = n;
    while (end > first && space(end - 1))
    {
        --end;
    }
    lines ~= Line(first, n, startOf(first), startOf(end) - startOf(first));
    return lines;
}

/// Atlas cache key: font, glyph and subpixel bin.
struct GlyphKey
{
    uint font;  /// `SizedFont.id` of the font
    uint glyph; /// glyph index
    ubyte bin;  /// horizontal offset in 1/subpixelBins of a pixel
}

/// Glyph bitmap placed in the atlas.
struct GlyphSlot
{
    short x;    /// left edge in the atlas, in texels
    short y;    /// top edge in the atlas, in texels
    short w;    /// bitmap width in texels, zero for blank glyphs
    short h;    /// bitmap height in texels
    short left; /// distance from the pen x to the left edge of the bitmap
    short top;  /// distance from the baseline up to the top edge of the bitmap
}

/// RGBA8 premultiplied atlas: a white block for untextured shapes, then glyphs packed in shelves.
/// Grows by doubling its height, so texel coordinates stay valid until `clear`.
final class GlyphAtlas
{
    int width;            /// width in texels
    int height;           /// height in texels
    ubyte[] pixels;       /// premultiplied RGBA8 rows, top first
    int dirtyTop = int.max; /// first changed row since `takeDirty`
    int dirtyBottom;      /// one past the last changed row
    bool resized = true;  /// size changed, upload everything
    bool full;            /// true when out of space, cleared before the next frame
    uint generation;      /// bumped by `clear`, meshes made before hold stale texel coordinates
    enum int maxHeight = 4096; /// tallest the atlas grows, in texels

    private GlyphSlot[GlyphKey] slots; /// placed glyphs
    private int shelfX;   /// next free x on the current shelf
    private int shelfY;   /// top of the current shelf
    private int shelfH;   /// height of the current shelf

    /// Creates an empty atlas `width` texels wide.
    this(int width = 1024, int height = 1024)
    {
        this.width = width;
        this.height = height;
        clear();
    }

    /// Drops every glyph and keeps the white block.
    void clear()
    {
        ++generation;
        pixels = new ubyte[width * height * 4];
        slots = null;
        pixels[0 .. 4 * 4] = 0xff;
        foreach (int y; 0 .. 4)
        {
            pixels[y * width * 4 .. y * width * 4 + 16] = 0xff;
        }
        shelfX = 5;
        shelfY = 0;
        shelfH = 5;
        full = false;
        resized = true;
        dirtyTop = 0;
        dirtyBottom = height;
    }

    /// Texel center of the white block, the UV of untextured vertices.
    static float whiteUV()
    {
        return 2;
    }

    /// Slot of `key`, or null if not placed yet.
    GlyphSlot* find(GlyphKey key)
    {
        return key in slots;
    }

    /// Places a `w` by `h` coverage bitmap with `pitch` bytes per row. Null when out of space.
    GlyphSlot* place(GlyphKey key, int w, int h, int pitch, const(ubyte)* src, int left, int top,
        const ref ubyte[256] curve)
    {
        if (w == 0 || h == 0)
        {
            slots[key] = GlyphSlot(0, 0, 0, 0, cast(short) left, cast(short) top);
            return key in slots;
        }
        if (shelfX + w + 1 > width)
        {
            shelfY += shelfH;
            shelfX = 0;
            shelfH = 0;
        }
        while (shelfY + h + 1 > height)
        {
            if (height * 2 > maxHeight)
            {
                full = true;
                return null;
            }
            grow();
        }
        int x = shelfX;
        int y = shelfY;
        foreach (int row; 0 .. h)
        {
            const(ubyte)* line = src + row * pitch;
            ubyte[] dst = pixels[((y + row) * width + x) * 4 .. ((y + row) * width + x + w) * 4];
            foreach (int col; 0 .. w)
            {
                ubyte c = curve[line[col]];
                dst[col * 4 .. col * 4 + 4] = c;
            }
        }
        shelfX += w + 1;
        shelfH = max(shelfH, h + 1);
        dirtyTop = min(dirtyTop, y);
        dirtyBottom = max(dirtyBottom, y + h);
        slots[key] = GlyphSlot(cast(short) x, cast(short) y, cast(short) w, cast(short) h,
            cast(short) left, cast(short) top);
        return key in slots;
    }

    /// Doubles the height, keeping texel coordinates.
    private void grow()
    {
        height *= 2;
        pixels.length = width * height * 4;
        resized = true;
    }

    /// Rows changed since the last call as `[top, bottom)`, then resets. Empty when clean.
    void takeDirty(out int top, out int bottom)
    {
        top = dirtyTop == int.max ? 0 : dirtyTop;
        bottom = dirtyTop == int.max ? 0 : dirtyBottom;
        dirtyTop = int.max;
        dirtyBottom = 0;
    }
}

/// Cache key of a shaped string.
private struct RunKey
{
    FontKind kind; /// slot
    uint size64;   /// logical size times 64
    bool tabular;  /// equal-width digits
    string text;   /// text shaped
}

/// Cached run and the frame it was last used in.
private struct CachedRun
{
    ShapedRun run; /// shaped text
    ulong used;    /// frame counter at last use
}

/// Atlas slot found lately, for the lookup cache of `TextSystem.glyph`.
private struct RecentGlyph
{
    GlyphKey key;    /// font, glyph and bin
    GlyphSlot* slot; /// placed glyph, null for an empty entry
}

/// Fonts, shaping cache and glyph atlas of one window.
final class TextSystem
{
    float ppp = 1;           /// physical pixels per logical pixel
    GlyphAtlas atlas;        /// glyph atlas shared by every run
    ulong frame;             /// frame counter for cache eviction
    float contrast = 1.0;    /// coverage exponent, below 1 darkens thin text
    int rasterized;          /// glyphs rasterized so far

    private FT_Library lib;                 /// FreeType library
    private immutable(ubyte)[][FontKind.max + 1] files; /// font file bytes per slot
    private string[] fallbacks;             /// fallback font files, tried in order
    private bool[] badFallback;             /// fallbacks that did not open
    private SizedFont[] sized;              /// every sized font, by id
    private SizedFont[ulong] bySize;        /// sized fonts by slot and size
    private CachedRun[RunKey] runs;         /// shaped strings
    private hb_buffer_t* buffer;            /// shaping buffer, reused
    private ubyte[256] curve;               /// coverage curve from `contrast`
    private RecentGlyph[1024] recent;       /// atlas lookups by a hash of their key, newest wins
    private uint recentGeneration;          /// atlas generation of `recent`

    /// Loads one font file per slot. `fallbacks` open when a character needs them, and bad ones are skipped.
    this(string[FontKind.max + 1] paths, string[] fallbacks = null)
    {
        this.fallbacks = fallbacks.dup;
        badFallback = new bool[fallbacks.length];
        import std.file : read;

        enforce(FT_Init_FreeType(&lib) == 0, "FreeType init failed");
        foreach (size_t i, string p; paths)
        {
            files[i] = cast(immutable(ubyte)[]) read(p);
        }
        buffer = hb_buffer_create();
        atlas = new GlyphAtlas;
        setContrast(contrast);
    }

    /// Frees fonts and the library.
    void dispose()
    {
        dropFonts();
        hb_buffer_destroy(buffer);
        FT_Done_FreeType(lib);
    }

    /// Sets the coverage exponent and clears the atlas.
    void setContrast(float c)
    {
        contrast = c;
        foreach (int i; 0 .. 256)
        {
            curve[i] = cast(ubyte) round(pow(i / 255.0, c) * 255);
        }
        atlas.clear();
    }

    /// Changes the scale. Every run and glyph is redone at the new size.
    void setScale(float scale)
    {
        if (scale == ppp)
        {
            return;
        }
        ppp = scale;
        dropFonts();
        runs = null;
        atlas.clear();
    }

    /// Frees every sized font.
    private void dropFonts()
    {
        foreach (SizedFont f; sized)
        {
            hb_font_destroy(f.hb);
            FT_Done_Face(f.face);
        }
        sized = null;
        bySize = null;
    }

    /// Font of `kind` at logical `size` and the current scale.
    SizedFont font(FontKind kind, float size)
    {
        return face(kind, size);
    }

    /// Fallback `i` at logical `size`, or null when its file does not open.
    private SizedFont fallback(size_t i, float size)
    {
        if (badFallback[i])
        {
            return null;
        }
        SizedFont f = face(FontKind.max + 1 + i, size);
        badFallback[i] = f is null;
        return f;
    }

    /// Font file `file`, a slot or a fallback after the slots, at logical `size`. Null when a fallback does not
    /// open.
    private SizedFont face(size_t file, float size)
    {
        uint px64 = cast(uint) round(size * ppp * 64);
        ulong key = (cast(ulong) file << 32) | px64;
        if (SizedFont* f = key in bySize)
        {
            return *f;
        }
        SizedFont f = new SizedFont;
        f.file = file;
        f.px = px64 / 64.0f;
        if (file <= FontKind.max)
        {
            immutable(ubyte)[] data = files[file];
            enforce(FT_New_Memory_Face(lib, data.ptr, cast(c_long) data.length, 0, &f.face) == 0, "bad font file");
        }
        else if (FT_New_Face(lib, fallbacks[file - FontKind.max - 1].toStringz, 0, &f.face) != 0)
        {
            return null;
        }
        f.id = cast(uint) sized.length;
        FT_Set_Char_Size(f.face, 0, px64, 72, 72);
        f.hb = hb_ft_font_create_referenced(f.face);
        float scale = f.px / f.face.units_per_EM;
        f.ascent = f.face.ascender * scale;
        f.descent = -f.face.descender * scale;
        f.lineGap = max(0f, f.face.height * scale - f.ascent - f.descent);
        sized ~= f;
        bySize[key] = f;
        return f;
    }

    /// Line height of `kind` at logical `size`, in logical pixels.
    float lineHeight(FontKind kind, float size)
    {
        SizedFont f = font(kind, size);
        return ceil(f.ascent + f.descent) / ppp;
    }

    /// Distance from the line top to the baseline, in logical pixels.
    float ascent(FontKind kind, float size)
    {
        SizedFont f = font(kind, size);
        return f.ascent / ppp;
    }

    /// `text` shaped with `kind` at logical `size`, from the cache when possible. `tabular` asks for
    /// equal-width digits.
    ShapedRun shape(FontKind kind, float size, string text, bool tabular = false)
    {
        RunKey key = RunKey(kind, cast(uint) round(size * 64), tabular, text);
        if (CachedRun* hit = key in runs)
        {
            hit.used = frame;
            return hit.run;
        }
        ShapedRun r = shapeUncached(font(kind, size), size, text, tabular);
        runs[RunKey(kind, key.size64, tabular, r.text)] = CachedRun(r, frame);
        return r;
    }

    /// Logical width of `text`.
    float measure(FontKind kind, float size, string text, bool tabular = false)
    {
        return shape(kind, size, text, tabular).width / ppp;
    }

    /// Shapes `text` with `f`, at logical `size`, and its fallbacks, with the `tnum` feature when `tabular`.
    private ShapedRun shapeUncached(SizedFont f, float size, string text, bool tabular)
    {
        ShapedRun r = new ShapedRun;
        r.text = text.idup;
        r.font = f;
        SizedFont current;
        size_t start;
        size_t i;
        while (i < r.text.length)
        {
            size_t at = i;
            dchar c = decode!(Yes.useReplacementDchar)(r.text, i);
            SizedFont want = fontFor(c, f, current, size);
            if (current !is null && want !is current)
            {
                shapePart(r, current, start, at, tabular);
                start = at;
            }
            current = want;
        }
        shapePart(r, current is null ? f : current, start, r.text.length, tabular);
        return r;
    }

    /// Font for `c`: `current` for marks and joiners after it, then `f`, then the first fallback having it, then
    /// `f` for its missing glyph.
    private SizedFont fontFor(dchar c, SizedFont f, SizedFont current, float size)
    {
        bool joins = isMark(c) || c == 0x200C || c == 0x200D || (c >= 0xFE00 && c <= 0xFE0F)
            || (c >= 0xE0100 && c <= 0xE01EF);
        if (current !is null && joins)
        {
            return current;
        }
        if (c < 0x80 || fallbacks.length == 0 || FT_Get_Char_Index(f.face, c) != 0)
        {
            return f;
        }
        foreach (size_t i; 0 .. fallbacks.length)
        {
            SizedFont g = fallback(i, size);
            if (g !is null && FT_Get_Char_Index(g.face, c) != 0)
            {
                return g;
            }
        }
        return f;
    }

    /// Shapes bytes `[start, end)` of `r.text` with `f` and appends the glyphs to `r`, with the rest of the text
    /// as context. Fills `r.faces` once a part uses a font other than `r.font`.
    private void shapePart(ShapedRun r, SizedFont f, size_t start, size_t end, bool tabular)
    {
        hb_buffer_clear_contents(buffer);
        hb_buffer_add_utf8(buffer, r.text.ptr, cast(int) r.text.length, cast(uint) start, cast(int)(end - start));
        hb_buffer_guess_segment_properties(buffer);
        hb_feature_t tnum = hb_feature_t(hbTag("tnum"), 1, 0, uint.max);
        hb_shape(f.hb, buffer, tabular ? &tnum : null, tabular ? 1 : 0);
        uint n;
        hb_glyph_info_t* infos = hb_buffer_get_glyph_infos(buffer, &n);
        hb_glyph_position_t* pos = hb_buffer_get_glyph_positions(buffer, &n);
        if (f !is r.font && r.faces.length < r.glyphs.length)
        {
            r.faces = new SizedFont[r.glyphs.length];
            r.faces[] = r.font;
        }
        float pen = r.width;
        foreach (uint i; 0 .. n)
        {
            r.glyphs ~= infos[i].codepoint;
            r.clusters ~= infos[i].cluster;
            r.pens ~= pen;
            r.xs ~= pen + pos[i].x_offset / 64.0f;
            r.ys ~= -pos[i].y_offset / 64.0f;
            pen += pos[i].x_advance / 64.0f;
            if (r.faces.length > 0 || f !is r.font)
            {
                r.faces ~= f;
            }
        }
        r.width = pen;
    }

    /// Atlas slot of glyph `glyph` of `f` at subpixel `bin`, rasterized on first use. Null when the atlas is full.
    GlyphSlot* glyph(SizedFont f, uint glyph, ubyte bin)
    {
        GlyphKey key = GlyphKey(f.id, glyph, bin);
        if (recentGeneration != atlas.generation)
        {
            recent[] = RecentGlyph.init;
            recentGeneration = atlas.generation;
        }
        RecentGlyph* r = &recent[((f.id * 0x9E3779B1u) ^ (glyph * subpixelBins + bin)) & (recent.length - 1)];
        if (r.slot !is null && r.key == key)
        {
            return r.slot;
        }
        GlyphSlot* s = atlas.find(key);
        if (s is null)
        {
            s = rasterize(f, key);
        }
        if (s !is null)
        {
            *r = RecentGlyph(key, s);
        }
        return s;
    }

    /// Rasterizes the glyph of `key` in `f` into the atlas. Null when the atlas is full.
    private GlyphSlot* rasterize(SizedFont f, GlyphKey key)
    {
        uint glyph = key.glyph;
        ubyte bin = key.bin;
        FT_Vector delta = FT_Vector(bin * 64 / subpixelBins, 0);
        FT_Set_Transform(f.face, null, &delta);
        scope (exit)
        {
            FT_Set_Transform(f.face, null, null);
        }
        if (FT_Load_Glyph(f.face, glyph, FT_LOAD_TARGET_LIGHT) != 0
            || FT_Render_Glyph(f.face.glyph, FT_RENDER_MODE_LIGHT) != 0)
        {
            return atlas.place(key, 0, 0, 0, null, 0, 0, curve);
        }
        FT_GlyphSlot g = f.face.glyph;
        ++rasterized;
        if (g.bitmap.pixel_mode != FT_PIXEL_MODE_GRAY)
        {
            return atlas.place(key, 0, 0, 0, null, 0, 0, curve);
        }
        return atlas.place(key, g.bitmap.width, g.bitmap.rows, g.bitmap.pitch, g.bitmap.buffer,
            g.bitmap_left, g.bitmap_top, curve);
    }

    /// Ends a frame: clears a full atlas and drops runs unused for `keep` frames.
    void endFrame(ulong keep = 600)
    {
        ++frame;
        if (atlas.full)
        {
            atlas.clear();
        }
        if (frame % 128 != 0)
        {
            return;
        }
        RunKey[] old;
        foreach (ref const RunKey k, ref CachedRun c; runs)
        {
            if (frame - c.used > keep)
            {
                old ~= k;
            }
        }
        foreach (RunKey k; old)
        {
            runs.remove(k);
        }
    }

    /// Number of cached runs.
    size_t cachedRuns() const
    {
        return runs.length;
    }
}

/// Well-known system fonts that exist here, in order: wide coverage first, then CJK, then symbols.
string[] systemFallbackFonts()
{
    import std.file : exists;
    import std.process : environment;

    string[] candidates;
    version (Windows)
    {
        string dir = environment.get("WINDIR", `C:\Windows`) ~ `\Fonts\`;
        foreach (string f; ["segoeui.ttf", "arial.ttf", "msyh.ttc", "YuGothR.ttc", "malgun.ttf", "Nirmala.ttf",
            "seguisym.ttf"])
        {
            candidates ~= dir ~ f;
        }
    }
    else version (OSX)
    {
        candidates = ["/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
            "/System/Library/Fonts/Hiragino Sans GB.ttc", "/System/Library/Fonts/AppleSDGothicNeo.ttc",
            "/System/Library/Fonts/Apple Symbols.ttf"];
    }
    else
    {
        foreach (string f; ["noto/NotoSans-Regular.ttf", "dejavu/DejaVuSans.ttf", "TTF/DejaVuSans.ttf",
            "dejavu-sans-fonts/DejaVuSans.ttf", "noto-cjk/NotoSansCJK-Regular.ttc",
            "google-noto-cjk/NotoSansCJK-Regular.ttc", "noto/NotoSansCJK-Regular.ttc",
            "droid/DroidSansFallbackFull.ttf", "wqy/wqy-microhei.ttc", "noto/NotoSansSymbols-Regular.ttf",
            "noto/NotoSansSymbols2-Regular.ttf"])
        {
            foreach (string dir; ["/usr/share/fonts/truetype/", "/usr/share/fonts/opentype/", "/usr/share/fonts/"])
            {
                candidates ~= dir ~ f;
            }
        }
    }
    string[] found;
    foreach (string p; candidates)
    {
        if (exists(p))
        {
            found ~= p;
        }
    }
    return found;
}

/// Glyph key bin and whole pixel pen for a glyph drawn at physical `x`.
ubyte subpixel(float x, out int penX)
{
    float whole = floor(x);
    int b = cast(int) round((x - whole) * subpixelBins);
    if (b == subpixelBins)
    {
        b = 0;
        whole += 1;
    }
    penX = cast(int) whole;
    return cast(ubyte) b;
}

version (unittest)
{
    /// Text system over the fonts in `fonts/`, for tests run from the repo root.
    TextSystem testText()
    {
        return new TextSystem(["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf",
            "fonts/JetBrainsMono-Regular.ttf"]);
    }
}

// Shaping: mono advances are equal, proportional ones are not, and scale multiplies widths.
unittest
{
    TextSystem t = testText();
    scope (exit)
    {
        t.dispose();
    }
    ShapedRun mono = t.shape(FontKind.mono, 13, "0x0040_1000");
    assert(mono.glyphs.length == 11);
    float adv = mono.xs[1] - mono.xs[0];
    assert(adv > 7 && adv < 8.5, format("%s", adv));
    assert(mono.width == adv * 11);
    float ui = t.measure(FontKind.ui, 13, "illegal");
    float wide = t.measure(FontKind.ui, 13, "MMMMMMM");
    assert(wide > ui * 1.5);
    assert(t.shape(FontKind.mono, 13, "0x0040_1000") is mono, "cached");

    t.setScale(2);
    assert(t.cachedRuns == 0);
    ShapedRun big = t.shape(FontKind.mono, 13, "0x0040_1000");
    assert(big.width > mono.width * 1.99 && big.width < mono.width * 2.01);
    assert(t.measure(FontKind.mono, 13, "0x0040_1000") == big.width / 2, "logical width");
}

// Carets map byte offsets to pen x and back.
unittest
{
    TextSystem t = testText();
    scope (exit)
    {
        t.dispose();
    }
    ShapedRun r = t.shape(FontKind.mono, 13, "abcd");
    float adv = r.width / 4;
    assert(r.caretX(0) == 0);
    assert(r.caretX(2) == adv * 2);
    assert(r.caretX(4) == r.width);
    assert(r.indexAt(adv * 1.4) == 1);
    assert(r.indexAt(adv * 1.6) == 2);
    assert(r.indexAt(1000) == 4);
}

// Wrapping breaks after spaces, drops trailing spaces from widths, and lets long words overflow.
unittest
{
    TextSystem t = testText();
    scope (exit)
    {
        t.dispose();
    }
    ShapedRun r = t.shape(FontKind.mono, 13, "one two three");
    float adv = r.width / 13;
    Line[] lines = wrap(r, adv * 8);
    assert(lines.length == 2);
    assert(lines[0].first == 0 && lines[0].last == 7 && lines[0].width == adv * 7, "one two");
    assert(lines[1].first == 8 && lines[1].width == adv * 5, "three");
    assert(wrap(r, 1000).length == 1);
    Line[] tight = wrap(r, adv * 2);
    assert(tight.length == 3 && tight[2].width == adv * 5, "overflowing words stay whole");
}

// The atlas packs glyphs, rasterizes each key once and grows without moving glyphs.
unittest
{
    TextSystem t = testText();
    scope (exit)
    {
        t.dispose();
    }
    SizedFont f = t.font(FontKind.ui, 13);
    GlyphSlot* a = t.glyph(f, t.shape(FontKind.ui, 13, "A").glyphs[0], 0);
    assert(a.w > 4 && a.h > 6 && a.top > 6);
    GlyphSlot first = *a;
    int count = t.rasterized;
    t.glyph(f, t.shape(FontKind.ui, 13, "A").glyphs[0], 0);
    assert(t.rasterized == count, "cached");
    t.glyph(f, t.shape(FontKind.ui, 13, "A").glyphs[0], 2);
    assert(t.rasterized == count + 1, "another bin is another glyph");

    GlyphAtlas small = new GlyphAtlas(64, 64);
    ubyte[100] ink = 255;
    ubyte[256] identity;
    foreach (int i; 0 .. 256)
    {
        identity[i] = cast(ubyte) i;
    }
    GlyphSlot* s = small.place(GlyphKey(0, 1, 0), 10, 10, 10, ink.ptr, 0, 0, identity);
    GlyphSlot keep = *s;
    foreach (uint g; 2 .. 40)
    {
        small.place(GlyphKey(0, g, 0), 10, 10, 10, ink.ptr, 0, 0, identity);
    }
    assert(small.height > 64 && small.full == false);
    assert(*small.find(GlyphKey(0, 1, 0)) == keep);
    assert(small.pixels[(keep.y * small.width + keep.x) * 4] == 255);
    int pen;
    assert(subpixel(10.3, pen) == 1 && pen == 10);
    assert(subpixel(10.9, pen) == 0 && pen == 11);
    assert(first.x >= 5, "after the white block");
}

// A character the slot font lacks comes from the first fallback having it, with clusters and pens running on,
// and characters no font has keep the slot font's missing glyph.
unittest
{
    string[FontKind.max + 1] slots = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf",
        "fonts/JetBrainsMono-Regular.ttf"];
    TextSystem plain = testText();
    TextSystem t = new TextSystem(slots, ["fonts/missing.ttf", "fonts/Inter-Regular.otf"]);
    scope (exit)
    {
        plain.dispose();
        t.dispose();
    }
    string s = "aἀb";
    ShapedRun before = plain.shape(FontKind.mono, 14, s);
    assert(before.glyphs[1] == 0 && before.faces.length == 0, "JetBrains Mono has no U+1F00");
    ShapedRun r = t.shape(FontKind.mono, 14, s);
    assert(r.glyphs.length == 3 && r.glyphs[1] != 0 && r.clusters == [0, 1, 4]);
    assert(r.faces.length == 3 && r.faces[0] is r.font && r.faces[2] is r.font);
    assert(r.faces[1].file == FontKind.max + 2, "the second fallback, the first does not open");
    assert(r.pens[1] == before.pens[1] && r.pens[2] > r.pens[1] && r.width > r.pens[2]);
    assert(t.shape(FontKind.mono, 14, "ab").faces.length == 0, "one font, no faces");
    ShapedRun none = t.shape(FontKind.mono, 14, "中");
    assert(none.glyphs == [0] && none.faces.length == 0);
}
