const std = @import("std");

// Sorted UTF-8 keys point to 16x16 tiles. Each tile has 15 RGB colors and
// two palette indices per byte. Index zero leaves the background visible.
const atlas = @embedFile("fonts/emoji.bin");
pub const Tile = [45 + 128]u8;
const Match = struct { tile: *const Tile, len: usize };

fn entry(index: usize) []const u8 {
    return atlas[8 + index * 8 ..][0..8];
}

fn key(record: []const u8) []const u8 {
    const offset = std.mem.readInt(u32, record[0..4], .little);
    const len = std.mem.readInt(u16, record[4..6], .little);
    return atlas[offset..][0..len];
}

pub fn match(text: []const u8) ?Match {
    if (text.len == 0) return null;
    // Only keycap sequences start with ASCII.
    if (text[0] < 128 and (text.len < 2 or text[1] < 128 or
        !(std.ascii.isDigit(text[0]) or text[0] == '#' or text[0] == '*'))) return null;
    const count = std.mem.readInt(u32, atlas[0..4], .little);
    var first: usize = 0;
    var end: usize = 0;
    var best: ?Match = null;
    while (end < text.len) {
        const size = std.unicode.utf8ByteSequenceLength(text[end]) catch break;
        if (size > text.len - end) break;
        end += size;
        const prefix = text[0..end];
        var high: usize = count;
        while (first < high) {
            const mid = first + (high - first) / 2;
            if (std.mem.order(u8, key(entry(mid)), prefix) == .lt) first = mid + 1 else high = mid;
        }
        if (first == count) break;
        const record = entry(first);
        const candidate = key(record);
        if (!std.mem.startsWith(u8, candidate, prefix)) break;
        if (candidate.len == end) {
            if (std.mem.startsWith(u8, text[end..], "\u{fe0e}")) return null;
            const tile_id = std.mem.readInt(u16, record[6..8], .little);
            const tiles = std.mem.readInt(u32, atlas[4..8], .little);
            const offset = tiles + @as(usize, tile_id) * @sizeOf(Tile);
            best = .{ .len = end, .tile = atlas[offset..][0..@sizeOf(Tile)] };
        }
    }
    return best;
}
