const std = @import("std");
const Track = @import("library.zig").Track;

pub fn matches(track: *const Track, query: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, query, " \t\n\r");
    while (words.next()) |word| {
        for ([_][]const u8{ track.title, track.artist, track.album, track.path }) |field| {
            if (std.ascii.findIgnoreCase(field, word) != null) break;
        } else return false;
    }
    return true;
}

pub const Input = struct {
    pub const capacity = 1024;
    data: [capacity]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    pub fn text(input: *const Input) []const u8 {
        return input.data[0..input.len];
    }

    pub fn insert(input: *Input, value: []const u8) bool {
        if (value.len == 0 or value.len > capacity - input.len or !std.unicode.utf8ValidateSlice(value)) return false;
        @memmove(input.data[input.cursor + value.len ..][0 .. input.len - input.cursor], input.data[input.cursor..input.len]);
        for (value, input.data[input.cursor..][0..value.len]) |byte, *out| out.* = if (byte < 32 or byte == 127) ' ' else byte;
        input.len += value.len;
        input.cursor += value.len;
        return true;
    }

    pub fn move(input: *Input, forward: bool) void {
        if (forward) {
            if (input.cursor == input.len) return;
            input.cursor += std.unicode.utf8ByteSequenceLength(input.data[input.cursor]) catch unreachable;
        } else {
            if (input.cursor == 0) return;
            input.cursor -= 1;
            while (input.data[input.cursor] & 0xc0 == 0x80) input.cursor -= 1;
        }
    }

    pub fn erase(input: *Input, forward: bool) bool {
        const old = input.cursor;
        input.move(forward);
        const begin = @min(old, input.cursor);
        const end = @max(old, input.cursor);
        @memmove(input.data[begin..][0 .. input.len - end], input.data[end..input.len]);
        input.len -= end - begin;
        input.cursor = begin;
        return end > begin;
    }
};

test "all search terms can match different fields in any order" {
    const track: Track = .{ .title = "東京 Nights", .artist = "Quartet", .album = "Live", .path = "sets/2025/show.mp3" };
    try std.testing.expect(matches(&track, "  LIVE art  東京 2025 niG "));
    try std.testing.expect(matches(&track, "  "));
    try std.testing.expect(!matches(&track, "quartet daylight"));
}

test "insert and delete preserve UTF-8 at the cursor" {
    var input: Input = .{};
    try std.testing.expect(input.insert("東🎵"));
    input.move(false);
    try std.testing.expect(input.insert("京"));
    try std.testing.expect(input.erase(true));
    try std.testing.expectEqualStrings("東京", input.text());
    try std.testing.expect(input.erase(false));
    try std.testing.expectEqualStrings("東", input.text());
    try std.testing.expect(!input.insert("\xff"));
}
