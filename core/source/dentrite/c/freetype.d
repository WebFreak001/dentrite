/// FreeType 2 subset: faces, sizes, glyph loading and rendering. Checked against FreeType 2.13 headers.
module dentrite.c.freetype;

import core.stdc.config : c_long, c_ulong;

extern (C) nothrow @nogc:

alias FT_Error = int;     /// 0 on success
alias FT_Pos = c_long;    /// 26.6 fixed point
alias FT_Fixed = c_long;  /// 16.16 fixed point
alias FT_F26Dot6 = c_long; /// 26.6 fixed point

/// Opaque library handle.
struct FT_LibraryRec;
alias FT_Library = FT_LibraryRec*; /// library handle

/// 2D vector in 26.6.
struct FT_Vector
{
    FT_Pos x; /// horizontal
    FT_Pos y; /// vertical
}

/// 2x2 matrix in 16.16.
struct FT_Matrix
{
    FT_Fixed xx, xy, yx, yy; /// coefficients
}

/// User data slot.
struct FT_Generic
{
    void* data;       /// user pointer
    void* finalizer;  /// destructor
}

/// Bounding box.
struct FT_BBox
{
    FT_Pos xMin, yMin, xMax, yMax; /// edges
}

/// Scaled metrics of a face at its current size.
struct FT_Size_Metrics
{
    ushort x_ppem;     /// horizontal pixels per EM
    ushort y_ppem;     /// vertical pixels per EM
    FT_Fixed x_scale;  /// font units to 26.6, horizontal
    FT_Fixed y_scale;  /// font units to 26.6, vertical
    FT_Pos ascender;   /// 26.6, rounded
    FT_Pos descender;  /// 26.6, rounded, negative
    FT_Pos height;     /// 26.6 line spacing
    FT_Pos max_advance; /// 26.6
}

/// Face size object.
struct FT_SizeRec
{
    FT_Face face;            /// owning face
    FT_Generic generic;      /// user data
    FT_Size_Metrics metrics; /// scaled metrics
    void* internal;          /// private
}

/// Glyph metrics in 26.6.
struct FT_Glyph_Metrics
{
    FT_Pos width, height, horiBearingX, horiBearingY, horiAdvance, vertBearingX, vertBearingY, vertAdvance; /// metrics
}

/// Rendered bitmap.
struct FT_Bitmap
{
    uint rows;          /// height
    uint width;         /// width in pixels
    int pitch;          /// bytes per row, negative for bottom-up
    ubyte* buffer;      /// pixels
    ushort num_grays;   /// gray levels
    ubyte pixel_mode;   /// FT_PIXEL_MODE_*
    ubyte palette_mode; /// unused
    void* palette;      /// unused
}

/// Outline, opaque here.
struct FT_Outline
{
    short n_contours; /// contours
    short n_points;   /// points
    FT_Vector* points; /// points
    ubyte* tags;      /// point tags
    short* contours;  /// contour ends
    int flags;        /// flags
}

/// Glyph slot of a face, valid until the next load.
struct FT_GlyphSlotRec
{
    FT_Library library;       /// library
    FT_Face face;             /// face
    FT_GlyphSlotRec* next;    /// next slot
    uint glyph_index;         /// loaded glyph
    FT_Generic generic;       /// user data
    FT_Glyph_Metrics metrics; /// metrics
    FT_Fixed linearHoriAdvance; /// unhinted advance, 16.16
    FT_Fixed linearVertAdvance; /// unhinted advance, 16.16
    FT_Vector advance;        /// transformed advance, 26.6
    uint format;              /// glyph format tag
    FT_Bitmap bitmap;         /// rendered bitmap
    int bitmap_left;          /// left bearing in pixels
    int bitmap_top;           /// top bearing in pixels, up positive
    FT_Outline outline;       /// outline
}

alias FT_GlyphSlot = FT_GlyphSlotRec*; /// glyph slot

/// Face, public part.
struct FT_FaceRec
{
    c_long num_faces;          /// faces in the file
    c_long face_index;         /// this face
    c_long face_flags;         /// FT_FACE_FLAG_*
    c_long style_flags;        /// style bits
    c_long num_glyphs;         /// glyph count
    char* family_name;         /// family
    char* style_name;          /// style
    int num_fixed_sizes;       /// bitmap strikes
    void* available_sizes;     /// strikes
    int num_charmaps;          /// charmaps
    void* charmaps;            /// charmaps
    FT_Generic generic;        /// user data
    FT_BBox bbox;              /// global box, font units
    ushort units_per_EM;       /// EM size
    short ascender;            /// font units
    short descender;           /// font units
    short height;              /// font units
    short max_advance_width;   /// font units
    short max_advance_height;  /// font units
    short underline_position;  /// font units
    short underline_thickness; /// font units
    FT_GlyphSlot glyph;        /// glyph slot
    FT_SizeRec* size;          /// active size
    void* charmap;             /// active charmap
}

alias FT_Face = FT_FaceRec*; /// face handle

version (X86_64) version (linux)
{
    static assert(FT_FaceRec.glyph.offsetof == 152 && FT_FaceRec.size.offsetof == 160);
    static assert(FT_SizeRec.metrics.offsetof == 24 && FT_Size_Metrics.sizeof == 56);
    static assert(FT_GlyphSlotRec.bitmap.offsetof == 152 && FT_GlyphSlotRec.bitmap_top.offsetof == 196);
    static assert(FT_Bitmap.sizeof == 40 && FT_Bitmap.pixel_mode.offsetof == 26);
}

enum int FT_LOAD_DEFAULT = 0;           /// hinted, default target
enum int FT_LOAD_NO_HINTING = 2;        /// unhinted outlines
enum int FT_LOAD_RENDER = 4;            /// render after loading
enum int FT_LOAD_TARGET_LIGHT = 0x10000; /// vertical-only hinting
enum int FT_RENDER_MODE_NORMAL = 0;     /// 8-bit gray
enum int FT_RENDER_MODE_LIGHT = 1;      /// 8-bit gray, light hinting
enum ubyte FT_PIXEL_MODE_GRAY = 2;      /// 8-bit gray bitmap

FT_Error FT_Init_FreeType(FT_Library* lib);            /// new library
FT_Error FT_Done_FreeType(FT_Library lib);             /// frees the library
/// Face over font bytes at `base`, which must outlive it.
FT_Error FT_New_Memory_Face(FT_Library lib, const(ubyte)* base, c_long size, c_long index, FT_Face* face);
FT_Error FT_New_Face(FT_Library lib, const(char)* path, c_long index, FT_Face* face); /// face from a font file
FT_Error FT_Done_Face(FT_Face face);                   /// frees a face
FT_Error FT_Set_Char_Size(FT_Face face, FT_F26Dot6 w, FT_F26Dot6 h, uint hres, uint vres); /// sets the size
FT_Error FT_Load_Glyph(FT_Face face, uint glyph, int flags); /// loads into the slot
FT_Error FT_Render_Glyph(FT_GlyphSlot slot, int mode); /// renders the slot
void FT_Set_Transform(FT_Face face, FT_Matrix* matrix, FT_Vector* delta); /// transform applied on load
uint FT_Get_Char_Index(FT_Face face, c_ulong charcode); /// glyph of a code point, 0 if missing
