/// Minimal PNG writer for screenshots: RGBA8, no filtering, zlib from Phobos.
module dentrite.png;

import std.bitmanip : nativeToBigEndian;
import std.digest.crc : crc32Of;
import std.zlib : compress;

/// PNG file bytes for `w` by `h` RGBA8 `pixels`, top row first.
ubyte[] encodePNG(const(ubyte)[] pixels, int w, int h)
{
    ubyte[] raw;
    raw.reserve((w * 4 + 1) * h);
    foreach (int y; 0 .. h)
    {
        raw ~= 0;
        raw ~= pixels[y * w * 4 .. (y + 1) * w * 4];
    }
    ubyte[] header;
    header ~= nativeToBigEndian(cast(uint) w);
    header ~= nativeToBigEndian(cast(uint) h);
    header ~= [8, 6, 0, 0, 0];
    ubyte[] png = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'];
    png ~= chunk("IHDR", header);
    png ~= chunk("IDAT", compress(raw, 6));
    png ~= chunk("IEND", null);
    return png;
}

/// Length, type, data and CRC of one chunk.
private ubyte[] chunk(string type, const(ubyte)[] data)
{
    ubyte[] typed = cast(ubyte[]) type.dup ~ data;
    ubyte[4] crc = crc32Of(typed);
    ubyte[] c;
    c ~= nativeToBigEndian(cast(uint) data.length);
    c ~= typed;
    c ~= [crc[3], crc[2], crc[1], crc[0]];
    return c;
}

// Signature, header size and the CRC of an empty IEND chunk.
unittest
{
    ubyte[] p = encodePNG([255, 0, 0, 255], 1, 1);
    assert(p[0 .. 8] == [0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n']);
    assert(p[8 .. 16] == [0, 0, 0, 13, 'I', 'H', 'D', 'R']);
    assert(p[$ - 4 .. $] == [0xAE, 0x42, 0x60, 0x82]);
}
