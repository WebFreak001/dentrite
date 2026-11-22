/// HarfBuzz subset: buffers, shaping, and fonts over FreeType faces.
module dentrite.c.harfbuzz;

import dentrite.c.freetype : FT_Face;

extern (C) nothrow @nogc:

struct hb_buffer_t; /// opaque buffer
struct hb_font_t;   /// opaque font

/// Shaped glyph: index and cluster.
struct hb_glyph_info_t
{
    uint codepoint; /// glyph index after shaping
    uint mask;      /// private
    uint cluster;   /// byte offset of the source text
    uint var1;      /// private
    uint var2;      /// private
}

/// Shaped glyph position, in the font's scale (26.6 for FreeType fonts).
struct hb_glyph_position_t
{
    int x_advance; /// pen advance
    int y_advance; /// pen advance
    int x_offset;  /// draw offset
    int y_offset;  /// draw offset
    uint var;      /// private
}

/// OpenType feature switch.
struct hb_feature_t
{
    uint tag;   /// four-character tag
    uint value; /// 0 off, 1 on
    uint start; /// first cluster
    uint end;   /// past last cluster
}

hb_buffer_t* hb_buffer_create();                               /// new buffer
void hb_buffer_destroy(hb_buffer_t* buf);                      /// frees a buffer
void hb_buffer_clear_contents(hb_buffer_t* buf);               /// empties a buffer for reuse
void hb_buffer_add_utf8(hb_buffer_t* buf, const(char)* text, int len, uint offset, int itemLen); /// adds text
void hb_buffer_guess_segment_properties(hb_buffer_t* buf);     /// script, language, direction
void hb_shape(hb_font_t* font, hb_buffer_t* buf, const(hb_feature_t)* features, uint count); /// shapes
hb_glyph_info_t* hb_buffer_get_glyph_infos(hb_buffer_t* buf, uint* length);         /// glyphs
hb_glyph_position_t* hb_buffer_get_glyph_positions(hb_buffer_t* buf, uint* length); /// positions
hb_font_t* hb_ft_font_create_referenced(FT_Face face);         /// font over a FreeType face
void hb_ft_font_changed(hb_font_t* font);                      /// re-reads the face size
void hb_font_destroy(hb_font_t* font);                         /// frees a font

/// Tag from four characters.
uint hbTag(string s) pure
{
    return (s[0] << 24) | (s[1] << 16) | (s[2] << 8) | s[3];
}
