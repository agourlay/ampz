const std = @import("std");
const mp3 = @import("mp3.zig");
const Allocator = std.mem.Allocator;

pub const Track = struct {
    path: []const u8,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    artists: []const []const u8 = &.{},
    number: u16 = 0,
    disc: u16 = 0,

    pub fn artistNames(t: *const Track) []const []const u8 {
        return if (t.artists.len != 0) t.artists else (&t.artist)[0..1];
    }

    pub fn hasArtist(t: *const Track, artist: []const u8) bool {
        for (t.artistNames()) |name| if (std.mem.eql(u8, name, artist)) return true;
        return false;
    }

    fn less(_: void, a: Track, b: Track) bool {
        const artist = std.ascii.orderIgnoreCase(a.artistNames()[0], b.artistNames()[0]);
        if (artist != .eq) return artist == .lt;
        const album = std.ascii.orderIgnoreCase(a.album, b.album);
        if (album != .eq) return album == .lt;
        if (a.disc != b.disc) return a.disc < b.disc;
        if (a.number != b.number) return a.number < b.number;
        const title = std.ascii.orderIgnoreCase(a.title, b.title);
        return if (title == .eq) std.mem.lessThan(u8, a.path, b.path) else title == .lt;
    }
};
pub fn scan(alloc: Allocator, io: std.Io, dir: std.Io.Dir) ![]Track {
    var tracks: std.ArrayList(Track) = .empty;
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (true) {
        const entry = (walker.next(io) catch |err| switch (err) {
            error.AccessDenied, error.FileNotFound => continue,
            else => return err,
        }) orelse break;
        if (entry.kind != .file or !std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.basename), ".mp3")) continue;
        const file = entry.dir.openFile(io, entry.basename, .{}) catch continue;
        defer file.close(io);
        const path = try alloc.dupe(u8, entry.path);
        const parent = std.fs.path.dirname(path) orelse "";
        const grandparent = std.fs.path.dirname(parent) orelse "";
        var track: Track = .{ .path = path, .title = std.fs.path.stem(path), .album = if (parent.len > 0) std.fs.path.basename(parent) else "Unknown album", .artist = if (grandparent.len > 0) std.fs.path.basename(grandparent) else "Unknown artist" };
        try readTags(alloc, io, file, &track);
        try tracks.append(alloc, track);
    }
    std.mem.sort(Track, tracks.items, {}, Track.less);
    return tracks.toOwnedSlice(alloc);
}
fn textValue(alloc: Allocator, encoding: u8, raw: []const u8) ![]const u8 {
    return decodeText(alloc, encoding, raw, false);
}

fn decodeText(alloc: Allocator, encoding: u8, raw: []const u8, default_le: bool) ![]const u8 {
    const value = std.mem.sliceTo(raw, 0);
    if (encoding == 3) return if (std.unicode.utf8ValidateSlice(value)) try alloc.dupe(u8, std.mem.trim(u8, value, " \r\n\t")) else "";
    var out: std.ArrayList(u8) = .empty;
    if (encoding == 0) {
        for (std.mem.trim(u8, value, " \r\n\t")) |v| {
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(v, &buf);
            try out.appendSlice(alloc, buf[0..n]);
        }
    } else if (encoding == 1 or encoding == 2) {
        const le = std.mem.startsWith(u8, raw, &.{ 255, 254 });
        const bom = le or std.mem.startsWith(u8, raw, &.{ 254, 255 });
        var i: usize = if (bom) 2 else 0;
        const endian: std.builtin.Endian = if (le or (!bom and default_le)) .little else .big;
        while (i + 2 <= raw.len) {
            const unit = std.mem.readInt(u16, raw[i..][0..2], endian);
            i += 2;
            if (unit == 0) break;
            var code: u21 = unit;
            if (std.unicode.utf16IsHighSurrogate(unit) and i + 2 <= raw.len) {
                const low = std.mem.readInt(u16, raw[i..][0..2], endian);
                code = std.unicode.utf16DecodeSurrogatePair(&.{ unit, low }) catch 0xfffd;
                if (std.unicode.utf16IsLowSurrogate(low)) i += 2;
            }
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(code, &buf) catch continue;
            try out.appendSlice(alloc, buf[0..n]);
        }
    }
    return out.toOwnedSlice(alloc);
}
fn readArtists(alloc: Allocator, track: *Track, encoding: u8, raw: []const u8) !void {
    const wide = encoding == 1 or encoding == 2;
    const step: usize = if (wide) 2 else 1;
    const little = encoding == 1 and std.mem.startsWith(u8, raw, "\xff\xfe");
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    var start: usize = 0;
    while (start < raw.len) {
        var end = start;
        while (end + step <= raw.len and !std.mem.allEqual(u8, raw[end..][0..step], 0)) end += step;
        const name = try decodeText(alloc, encoding, raw[start..end], little);
        if (name.len != 0) try names.append(alloc, name);
        start = end + step;
    }
    if (names.items.len == 0) return;
    track.artist = if (names.items.len == 1) names.items[0] else try std.mem.join(alloc, ", ", names.items);
    track.artists = if (names.items.len == 1) &.{} else try names.toOwnedSlice(alloc);
}

fn number(s: []const u8) u16 {
    return std.fmt.parseInt(u16, std.mem.sliceTo(s, '/'), 10) catch 0;
}
// In v2.2/v2.3, stored frame lengths count bytes before the whole tag was
// escaped. Track the previous byte across reads, including skipped frames.
fn isStuffing(previous_ff: *bool, byte: u8) bool {
    const stuffed = previous_ff.* and byte == 0;
    previous_ff.* = byte == 0xff;
    return stuffed;
}

const TagBody = struct {
    file: *std.Io.File.Reader,
    end: u64,
    unsync: bool,
    previous_ff: bool = false,

    fn read(body: *TagBody, dst: []u8) !void {
        if (dst.len > body.end - body.file.logicalPos()) return error.EndOfStream;
        if (!body.unsync) return body.file.interface.readSliceAll(dst);
        for (dst) |*out| {
            while (body.file.logicalPos() < body.end) {
                const byte = try body.file.interface.takeByte();
                if (!isStuffing(&body.previous_ff, byte)) {
                    out.* = byte;
                    break;
                }
            } else return error.EndOfStream;
        }
    }

    fn skip(body: *TagBody, length: usize) !void {
        if (length > body.end - body.file.logicalPos()) return error.EndOfStream;
        if (!body.unsync) return body.file.seekBy(@intCast(length));
        var scratch: [4096]u8 = undefined;
        var left = length;
        while (left > 0) {
            const n = @min(left, scratch.len);
            try body.read(scratch[0..n]);
            left -= n;
        }
    }
};

const TagField = enum { title, artist, album, number, disc };
const tag_fields = std.StaticStringMap(TagField).initComptime(.{
    .{ "TT2", .title }, .{ "TIT2", .title }, .{ "TP1", .artist }, .{ "TPE1", .artist },
    .{ "TAL", .album }, .{ "TALB", .album }, .{ "TRK", .number }, .{ "TRCK", .number },
    .{ "TPA", .disc },  .{ "TPOS", .disc },
});

fn readTags(alloc: Allocator, io: std.Io, file: std.Io.File, track: *Track) !void {
    var end = (file.stat(io) catch return).size;
    const Span = struct { start: u64, end: u64 };
    var appended: std.ArrayList(Span) = .empty;
    defer appended.deinit(alloc);
    const source: mp3.TagSource = .{ .file = .{ .handle = file, .io = io } };
    var legacy_offset: ?u64 = null;
    while (mp3.TrailingTag.endingAt(source, end)) |tag| {
        switch (tag.kind) {
            .id3v2 => try appended.append(alloc, .{ .start = tag.start, .end = end }),
            .id3v1 => if (legacy_offset == null) {
                legacy_offset = tag.start;
            },
            .ape => {},
        }
        end = tag.start;
    }
    if (legacy_offset) |offset| {
        var tag: [128]u8 = undefined;
        if ((file.readPositionalAll(io, &tag, offset) catch 0) == tag.len) {
            inline for (.{ "title", "artist", "album" }, .{ 3, 33, 63 }) |field, field_offset| {
                const text = try textValue(alloc, 0, tag[field_offset..][0..30]);
                if (text.len > 0) @field(track, field) = text;
            }
            if (tag[125] == 0) track.number = tag[126];
        }
    }
    const fallback = track.*;
    try readId3v2(alloc, io, file, 0, end, track, &fallback);
    while (appended.pop()) |span| try readId3v2(alloc, io, file, span.start, span.end, track, &fallback);
}

fn readId3v2(alloc: Allocator, io: std.Io, file: std.Io.File, start_offset: u64, end: u64, track: *Track, fallback: *const Track) !void {
    var header: [10]u8 = undefined;
    if (end - start_offset < header.len or (file.readPositionalAll(io, &header, start_offset) catch 0) != header.len) return;
    const version = header[3];
    const flags = header[5];
    const total = mp3.tagSize(&header);
    if (total == 0 or version < 2 or version > 4) return;
    if (version == 2 and flags & 0x40 != 0) return; // compressed tag
    const footer: usize = if (version == 4 and flags & 0x10 != 0) 10 else 0;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    reader.seekTo(start_offset + 10) catch return;
    var body: TagBody = .{
        .file = &reader,
        .end = start_offset + @min(total - footer, end - start_offset),
        .unsync = version < 4 and flags & 0x80 != 0,
    };
    var update = false;
    if (flags & 0x40 != 0) {
        body.read(header[0..4]) catch return;
        // v2.3 excludes the size field itself, v2.4 includes it.
        const remaining = if (version == 3) std.mem.readInt(u32, header[0..4], .big) else blk: {
            const ext = syncSize(header[0..4]);
            if (ext < 6) return;
            body.read(header[0..2]) catch return;
            if (header[0] != 1) return;
            update = header[1] & 0x40 != 0;
            break :blk ext - 6;
        };
        body.skip(remaining) catch return;
    }

    // A later ID3v2 tag replaces earlier ID3v2 fields unless marked as an update.
    if (!update) track.* = fallback.*;
    const prefix: usize = if (version == 2) 6 else 10;
    while (true) {
        body.read(header[0..prefix]) catch return;
        if (header[0] == 0) return;
        const id = header[0..if (version == 2) @as(usize, 3) else 4];
        const length: usize = switch (version) {
            2 => std.mem.readInt(u24, header[3..6], .big),
            3 => std.mem.readInt(u32, header[4..8], .big),
            else => syncSize(header[4..8]),
        };
        const field = tag_fields.get(id);
        const format: u8 = if (version == 2) 0 else header[9];
        const supported: u8 = if (version == 4) 0x43 else 0x20;
        var data: [8192]u8 = undefined;
        if (field == null or length < 2 or length > data.len or format & ~supported != 0) {
            body.skip(length) catch return;
            continue;
        }
        body.read(data[0..length]) catch return;
        var n = length;
        if (version == 4 and (flags & 0x80 != 0 or format & 0x02 != 0)) {
            // v2.4 stores each frame's escaped length, even if all frames are escaped.
            var previous_ff = false;
            n = 0;
            for (data[0..length]) |byte| {
                if (isStuffing(&previous_ff, byte)) continue;
                data[n] = byte;
                n += 1;
            }
        }
        const grouped = format & (if (version == 4) @as(u8, 0x40) else 0x20) != 0;
        var start: usize = @intFromBool(grouped);
        if (version == 4 and format & 1 != 0) start += 4; // data length indicator
        if (start >= n) continue;
        if (field.? == .artist and version == 4) {
            try readArtists(alloc, track, data[start], data[start + 1 .. n]);
            continue;
        }
        const text = try textValue(alloc, data[start], data[start + 1 .. n]);
        if (text.len == 0) continue;
        switch (field.?) {
            .title => track.title = text,
            .artist => {
                track.artist = text;
                track.artists = &.{};
            },
            .album => track.album = text,
            .number => track.number = number(text),
            .disc => track.disc = number(text),
        }
    }
}
fn syncSize(bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |b| n = n * 128 + (b & 127);
    return n;
}

test "latin1 and UTF16 tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("Björk", try textValue(alloc, 0, "Bj\xf6rk"));
    try std.testing.expectEqualStrings("東京", try textValue(alloc, 1, &.{ 254, 255, 0x67, 0x71, 0x4e, 0xac, 0, 0 }));
    try std.testing.expectEqual(@as(u16, 3), number("03/14"));
}

test "UTF-16 titles decode supplementary glyphs and preserve text after an unpaired surrogate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("🎶!", try textValue(alloc, 1, "\xff\xfe\x3c\xd8\xb6\xdf!\x00"));
    try std.testing.expectEqualStrings("🎶!", try textValue(alloc, 2, "\xd8\x3c\xdf\xb6\x00!"));
    try std.testing.expectEqualStrings("�A", try textValue(alloc, 2, "\xd8\x3c\x00A"));
}

test "ID3 unsynchronisation preserves text and subsequent frame boundaries" {
    // Tag-wide escaping in v2.2 and v2.3 can insert bytes anywhere, including
    // inside artwork that we skip. Their frame lengths are unescaped lengths.
    const v22 = "PIC\x00\x00\x03" ++ "\x01\xff\x00\xe1" ++
        "TT2\x00\x00\x03" ++ "\x00\xff\x00\xe0" ++ "TP1\x00\x00\x02\x00A";
    const v23 = "\x00\x00\x00\x06" ++ "\x00\x00\x00\x00\x00\x00" ++
        "APIC\x00\x00\x00\x03\x00\x00" ++ "\x01\xff\x00\xe1" ++
        "TIT2\x00\x00\x00\x03\x00\x00" ++ "\x00\xff\x00\xe0" ++ "TPE1\x00\x00\x00\x02\x00\x00\x00A";
    // v2.4 records the on-disk length. This frame also has a data length indicator.
    const v24 = "TIT2\x00\x00\x00\x08\x00\x03" ++ "\x00\x00\x00\x03" ++ "\x00\xff\x00\xe0" ++
        "TPE1\x00\x00\x00\x02\x00\x00\x00A";
    const cases = [_]struct { version: u8, flags: u8, body: []const u8 }{
        .{ .version = 2, .flags = 0x80, .body = v22 }, .{ .version = 3, .flags = 0xc0, .body = v23 },
        .{ .version = 4, .flags = 0, .body = v24 },    .{ .version = 4, .flags = 0x80, .body = v24 },
    };
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (cases) |case| {
        var tag: [128]u8 = undefined;
        tag[0..10].* = .{ 'I', 'D', '3', case.version, 0, case.flags, 0, 0, 0, @intCast(case.body.len) };
        @memcpy(tag[10..][0..case.body.len], case.body);
        try dir.dir.writeFile(io, .{ .sub_path = "tagged.mp3", .data = tag[0 .. 10 + case.body.len] });
        const file = try dir.dir.openFile(io, "tagged.mp3", .{});
        defer file.close(io);
        var track: Track = .{ .path = "", .title = "", .artist = "", .album = "" };
        try readTags(arena.allocator(), io, file, &track);
        try std.testing.expectEqualStrings("ÿà", track.title);
        try std.testing.expectEqualStrings("A", track.artist);
    }
}

test "v2.4 artist lists retain distinct names and inherited UTF-16 byte order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var track: Track = .{ .path = "", .artist = "", .title = "", .album = "" };
    for ([_][]const u8{ "A\x00Guest", "\xff\xfeA\x00\x00\x00G\x00u\x00e\x00s\x00t\x00", "\x00A\x00\x00\x00G\x00u\x00e\x00s\x00t" }, [_]u8{ 3, 1, 2 }) |raw, encoding| {
        try readArtists(arena.allocator(), &track, encoding, raw);
        try std.testing.expect(track.hasArtist("Guest"));
        try std.testing.expectEqualStrings("A, Guest", track.artist);
    }
}
