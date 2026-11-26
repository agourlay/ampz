const std = @import("std");

pub const size = 32;
pub const foreground = 0xffab85;
pub const background = 0x242c2b;

// Rasterized from the README vector for the native X11 renderer:
// magick -background none -density 768 src/assets/playhead.svg -filter box -resize 32x32 -depth 8 BGRA:src/assets/playhead-32.bgra
const pixels: *const [size * size * 4]u8 = @embedFile("assets/playhead-32.bgra");

// X11 expects two little-endian CARDINAL dimensions, then ARGB pixels in wire order.
const dimension = std.mem.toBytes(std.mem.nativeToLittle(u32, size));
pub const icon = dimension ++ dimension ++ pixels.*;

pub fn headerColor(x: usize, y: usize) u32 {
    const pixel = std.mem.readInt(u32, pixels[4 * (y * size + x) ..][0..4], .little);
    // Only the rounded dark tile corners have transparency. They blend into the header.
    return if (pixel >> 24 == 255) pixel & 0xffffff else background;
}
