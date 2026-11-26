const std = @import("std");
const mp3 = @import("mp3.zig");
const pulse = @import("pulse.zig");

const Trimming = struct { lead: usize = 0, tail: usize = 0 };
fn xing(first: mp3.Frame) ?Trimming {
    const start = first.h.dataStart();
    // LAME keeps Info/Xing at the same offset with or without CRC protection.
    if (first.h.crc) {
        if (xingAt(first.bytes[start - 2 ..])) |trim| return trim;
    }
    return xingAt(first.bytes[start..]);
}

fn xingAt(bytes: []const u8) ?Trimming {
    if (bytes.len < 8) return null;
    const tag = bytes[0..4];
    if (!std.mem.eql(u8, tag, "Info") and !std.mem.eql(u8, tag, "Xing")) return null;
    const flags = std.mem.readInt(u32, bytes[4..8], .big);
    var enc: usize = 8;
    for ([_]usize{ 4, 4, 100, 4 }, 0..) |size, i| {
        if (flags & (@as(u32, 1) << @intCast(i)) != 0) enc += size;
    }
    if (enc + 24 > bytes.len) return .{};
    const name = bytes[enc..][0..4];
    if (!std.mem.eql(u8, name, "LAME") and !std.mem.eql(u8, name, "Lavc") and !std.mem.eql(u8, name, "Lavf")) return .{};
    const gap = std.mem.readInt(u24, bytes[enc + 21 ..][0..3], .big);
    if (gap == 0) return .{};
    return .{ .lead = (gap >> 12) + 529, .tail = (gap & 4095) -| 529 };
}

pub const Song = struct {
    data: []const u8,
    frames: []usize,
    format: mp3.Header,
    lead: usize,
    length: usize,
    pub fn load(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Song {
        const data = try dir.readFileAlloc(io, path, alloc, .unlimited);
        errdefer alloc.free(data);
        var frames: std.ArrayList(usize) = .empty;
        defer frames.deinit(alloc);
        const audio = mp3.withoutTrailingTags(data);
        var pos = mp3.tagSize(audio);
        const first = mp3.next(audio, &pos) orelse return error.NoLayerIIIFrames;
        const trim = xing(first);
        if (trim == null) try frames.append(alloc, pos - first.h.size);
        while (mp3.next(audio, &pos)) |frame| {
            if (frame.h.rate != first.h.rate or frame.h.channels != first.h.channels) return error.ChangingAudioFormat;
            try frames.append(alloc, pos - frame.h.size);
        }
        const total = frames.items.len * first.h.samples();
        const gap = trim orelse Trimming{};
        if (total <= gap.lead + gap.tail) return error.EmptyTrack;
        return .{ .data = data, .frames = try frames.toOwnedSlice(alloc), .format = first.h, .lead = gap.lead, .length = total - gap.lead - gap.tail };
    }
    pub fn deinit(s: *Song, alloc: std.mem.Allocator) void {
        alloc.free(s.data);
        alloc.free(s.frames);
    }
    fn prime(s: *const Song, frame: usize, d: *mp3.Decoder, buf: *[2304]i16) !void {
        d.* = .{};
        // Two complete frames rebuild the hybrid overlap and synthesis history.
        const first = frame -| 2;
        var previous = first;
        var remaining = d.reservoir.len;
        while (remaining > 0 and previous > 0) {
            previous -= 1;
            const bytes = s.data[s.frames[previous]..];
            const h = mp3.Header.parse(bytes).?;
            const n = @min(remaining, h.size - h.dataStart());
            @memcpy(d.reservoir[remaining - n .. remaining], bytes[h.size - n .. h.size]);
            remaining -= n;
        }
        d.available = d.reservoir.len - remaining;
        @memmove(d.reservoir[0..d.available], d.reservoir[remaining..]);
        for (first..frame) |i| try s.decode(i, d, buf);
    }
    fn decode(s: *const Song, i: usize, d: *mp3.Decoder, buf: *[2304]i16) !void {
        const bytes = s.data[s.frames[i]..];
        const h = mp3.Header.parse(bytes).?;
        _ = try d.decode(h, bytes[0..h.size], buf);
    }
};
pub const Player = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    settings: pulse.Settings,
    song: ?Song = null,
    stream: ?pulse.Stream = null,
    track: ?usize = null,
    paused: bool = false,
    decoder: mp3.Decoder = .{},
    buffer: [2304]i16 = undefined,
    position: usize = 0,
    decoded_frame: ?usize = null,
    volume: usize = 100,

    pub fn stop(p: *Player) void {
        if (p.stream) |*s| s.close();
        if (p.song) |*s| s.deinit(p.alloc);
        p.stream = null;
        p.song = null;
        p.track = null;
        p.position = 0;
        p.paused = false;
    }
    pub fn play(p: *Player, idx: usize, path: []const u8) !void {
        p.stop();
        errdefer p.stop();
        p.song = try Song.load(p.alloc, p.io, p.dir, path);
        p.track = idx;
        try p.seek(0);
    }
    pub fn seek(p: *Player, target: usize) !void {
        const song = p.song orelse return;
        if (p.stream) |*s| s.close();
        p.stream = null;
        p.decoded_frame = null;
        errdefer p.stop();
        p.position = @min(target, song.length - 1);
        const frame = (p.position + song.lead) / song.format.samples();
        try song.prime(frame, &p.decoder, &p.buffer);
        p.stream = try pulse.Stream.open(&p.settings, song.format.rate, song.format.channels);
        if (p.paused) try p.stream.?.pause(true);
    }
    pub fn toggle(p: *Player) !void {
        if (p.stream) |*s| {
            try s.pause(!p.paused);
            p.paused = !p.paused;
        }
    }
    pub fn pump(p: *Player) !void {
        const song = p.song orelse return;
        const s = if (p.stream) |*stream| stream else return;
        if (p.paused or s.drain_tag != null) return;
        const ch = song.format.channels;
        const per = song.format.samples();
        while (s.credit >= ch * 2 and p.position < song.length) {
            const pos = p.position + song.lead;
            const i = pos / per;
            if (p.decoded_frame != i) {
                try song.decode(i, &p.decoder, &p.buffer);
                p.decoded_frame = i;
            }
            const n = @min(s.credit / (2 * ch), per - pos % per, song.length - p.position);
            const raw = p.buffer[(pos % per) * ch ..][0 .. n * ch];
            var bytes: [4608]u8 = undefined;
            for (raw, 0..) |sample, k| {
                const scaled = @divTrunc(@as(i32, sample) * @as(i32, @intCast(p.volume)), 100);
                std.mem.writeInt(i16, bytes[k * 2 ..][0..2], @intCast(scaled), .little);
            }
            try s.write(bytes[0 .. raw.len * 2]);
            p.position += n;
        }
        if (p.position == song.length) try s.drain();
    }
};

test "tagged folder to trimmed mono and stereo PCM" {
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{ .iterate = true });
    defer dir.cleanup();
    try dir.dir.createDirPath(io, "nested");
    try dir.dir.writeFile(io, .{ .sub_path = "nested/first.MP3", .data = @embedFile("fixtures/mono.mp3") });
    try dir.dir.writeFile(io, .{ .sub_path = "second.mp3", .data = @embedFile("fixtures/stereo.mp3") });
    try dir.dir.writeFile(io, .{ .sub_path = "ignore.txt", .data = "" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tracks = try @import("library.zig").scan(arena.allocator(), io, dir.dir);
    try std.testing.expectEqual(@as(usize, 2), tracks.len);
    try std.testing.expectEqualStrings("Low rate", tracks[0].title);
    try std.testing.expectEqualStrings("Two tones", tracks[1].title);
    // Signed 16-bit reference samples from FFmpeg's independent decoder.
    const reference = [2][8]i16{ .{ 221, -4390, -5423, -4575, -2025, 3742, -2941, 3339 }, .{ 51, 4343, -4012, -4589, -442, -783, 1117, 4066 } };
    for (tracks, 0..) |track, j| {
        try std.testing.expectEqualStrings("ampz", track.artist);
        try std.testing.expectEqualStrings("Test signals", track.album);
        var song = try Song.load(std.testing.allocator, io, dir.dir, track.path);
        defer song.deinit(std.testing.allocator);
        const length = song.length * song.format.channels;
        try std.testing.expectEqual(([_]usize{ 3040, 14112 })[j], length);
        var dec: mp3.Decoder = .{};
        var buf: [2304]i16 = undefined;
        var checked: usize = 0;
        const n = song.format.samples() * song.format.channels;
        for (0..song.frames.len) |frame| {
            try song.decode(frame, &dec, &buf);
            for ([_]usize{ 0, 37, 101, 333, 1000, 2000, 2500, length - 1 }, reference[j]) |i, sample| {
                const raw = i + song.lead * song.format.channels;
                if (raw / n == frame) {
                    try std.testing.expect(@abs(@as(i32, buf[raw % n]) - sample) <= 1);
                    checked += 1;
                }
            }
        }
        try std.testing.expectEqual(@as(usize, 8), checked);
    }
}

test "LAME CRC-protected Info frame preserves gapless length" {
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(io, .{ .sub_path = "crc.mp3", .data = @embedFile("fixtures/crc.mp3") });
    var song = try Song.load(std.testing.allocator, io, dir.dir, "crc.mp3");
    defer song.deinit(std.testing.allocator);
    try std.testing.expect(song.format.crc);
    try std.testing.expectEqual(@as(usize, 4410), song.length);
    try std.testing.expectEqual(@as(usize, 1105), song.lead);
}

test "stacked APEv2 and ID3v1 tags stay outside the audio frame index" {
    const stereo = @embedFile("fixtures/stereo.mp3").*;
    // An attached binary item containing a valid stream of a different sample rate.
    const value = "sample.mp3\x00" ++ @embedFile("fixtures/mono.mp3").*;
    const item = std.mem.toBytes(std.mem.nativeToLittle(u32, value.len)) ++ "\x02\x00\x00\x00" ++ "Sample\x00" ++ value;
    const common = "APETAGEX" ++ "\xd0\x07\x00\x00" ++ std.mem.toBytes(std.mem.nativeToLittle(u32, item.len + 32)) ++ "\x01\x00\x00\x00";
    const reserved: [8]u8 = @splat(0);
    const header = common ++ "\x00\x00\x00\xa0" ++ reserved;
    const footer = common ++ "\x00\x00\x00\x80" ++ reserved;
    const standalone_footer = common ++ "\x00\x00\x00\x00" ++ reserved;
    const id3v1 = "TAG" ++ @as([125]u8, @splat(0));

    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(io, .{ .sub_path = "art.mp3", .data = stereo ++ header ++ item ++ footer ++ id3v1 });
    var song = try Song.load(std.testing.allocator, io, dir.dir, "art.mp3");
    defer song.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 7056), song.length);
    try std.testing.expectEqualSlices(u8, &stereo, mp3.withoutTrailingTags(stereo ++ id3v1 ++ item ++ standalone_footer));
    const id3_flags_and_size = "\x04\x00\x10\x00\x00\x00\x02";
    const appended_id3 = "ID3" ++ id3_flags_and_size ++ "\x00\x00" ++ "3DI" ++ id3_flags_and_size;
    try std.testing.expectEqualSlices(u8, &stereo, mp3.withoutTrailingTags(stereo ++ appended_id3));
}

test "appended ID3v2.4 metadata with an embedded TAG marker is indexed once" {
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{ .iterate = true });
    defer dir.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const title = "TIT2\x00\x00\x00\x10\x00\x00\x03Evening session";
    const comment = "COMM\x00\x00\x00\x7b\x00\x00\x03eng\x00TAG" ++ @as([115]u8, @splat(' '));
    const body = title ++ comment;
    const flags_size = [_]u8{ 4, 0, 0x10, 0, 0, body.len / 128, body.len % 128 };
    const appended = "ID3" ++ flags_size ++ body ++ "3DI" ++ flags_size;
    try std.testing.expectEqualStrings("TAG", appended[appended.len - 128 ..][0..3]);
    const ordinary = @embedFile("fixtures/mono.mp3");
    const audio = ordinary[mp3.tagSize(ordinary)..];
    // A real ID3v1 tag outside the v2.4 footer supplies missing fields.
    var legacy: [128]u8 = @splat(0);
    @memcpy(legacy[0..3], "TAG");
    @memcpy(legacy[33..39], "Artist");
    const combined = try std.mem.concat(alloc, u8, &.{ audio, appended, &legacy });
    try std.testing.expectEqualSlices(u8, audio, mp3.withoutTrailingTags(combined));
    try dir.dir.writeFile(io, .{ .sub_path = "evening.mp3", .data = combined });
    const tracks = try @import("library.zig").scan(alloc, io, dir.dir);
    try std.testing.expectEqualStrings("Evening session", tracks[0].title);
    try std.testing.expectEqualStrings("Artist", tracks[0].artist);
    var song = try Song.load(std.testing.allocator, io, dir.dir, tracks[0].path);
    defer song.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3040), song.length);
}

test "appended ID3v2.4 updates inherit earlier fields and replacements use the fallback" {
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{ .iterate = true });
    defer dir.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const title = "TIT2\x00\x00\x00\x06\x00\x00\x03Final";
    const ext = "\x00\x00\x00\x07\x01\x40\x00";
    const update = [_]u8{ 4, 0, 0x50, 0, 0, 0, title.len + ext.len };
    const replacement = [_]u8{ 4, 0, 0x10, 0, 0, 0, title.len };
    const original = @embedFile("fixtures/mono.mp3").*;
    try dir.dir.writeFile(io, .{ .sub_path = "a.mp3", .data = original ++ "ID3" ++ update ++ ext ++ title ++ "3DI" ++ update });
    try dir.dir.writeFile(io, .{ .sub_path = "b.mp3", .data = original ++ "ID3" ++ replacement ++ title ++ "3DI" ++ replacement });
    const tracks = try @import("library.zig").scan(arena.allocator(), io, dir.dir);
    try std.testing.expectEqual(@as(usize, 2), tracks.len);
    for (tracks) |track| {
        try std.testing.expectEqualStrings("Final", track.title);
        try std.testing.expectEqualStrings(if (track.path[0] == 'a') "Test signals" else "Unknown album", track.album);
    }
}

test "playback obeys byte credit, applies volume and drains once at the trimmed end" {
    const socket = @import("socket.zig");
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(io, .{ .sub_path = "mono.mp3", .data = @embedFile("fixtures/mono.mp3") });
    var p: Player = .{ .alloc = std.testing.allocator, .io = io, .dir = dir.dir, .settings = .{ .path = "" }, .volume = 50 };
    defer p.stop();
    p.song = try Song.load(p.alloc, io, p.dir, "mono.mp3");
    const song = &p.song.?;
    for (0..song.lead / song.format.samples()) |i| try song.decode(i, &p.decoder, &p.buffer);
    const fds = try @import("test_socket.zig").pair();
    defer socket.close(fds[1]);
    p.stream = .{ .fd = fds[0], .channel = 17, .credit = 3 };

    // A single leftover byte cannot hold another complete mono sample.
    try p.pump();
    try std.testing.expectEqual(1, p.position);
    try std.testing.expectEqual(1, p.stream.?.credit);
    try p.pump();
    try std.testing.expectEqual(1, p.position);

    // A PulseAudio REQUEST grants enough additional bytes to finish the clip.
    const request = "\x00\x00\x00\x14" ++ "\xff\xff\xff\xff" ++ @as([12]u8, @splat(0)) ++
        "L\x00\x00\x00\x3dL\xff\xff\xff\xffL\x00\x00\x00\x11L\x00\x00\x20\x00";
    try socket.write(fds[1], request);
    try p.stream.?.event();
    try p.pump();
    try std.testing.expectEqual(song.length, p.position);
    try std.testing.expect(p.stream.?.drain_tag != null);
    try p.pump();

    var pcm: [3040 * 2]u8 = undefined;
    var pos: usize = 0;
    var header: [20]u8 = undefined;
    while (pos < pcm.len) {
        try socket.read(fds[1], &header);
        try std.testing.expectEqual(17, std.mem.readInt(u32, header[4..8], .big));
        const size = std.mem.readInt(u32, header[0..4], .big);
        try std.testing.expect(size > 0 and size % 2 == 0 and size <= pcm.len - pos);
        try socket.read(fds[1], pcm[pos..][0..size]);
        pos += size;
    }
    for ([_]usize{ 0, 37, 101, 333, 3039 }, [_]i16{ 221, -4390, -5423, -4575, 3339 }) |sample, reference| {
        const actual = std.mem.readInt(i16, pcm[sample * 2 ..][0..2], .little);
        try std.testing.expect(@abs(@as(i32, actual) - @divTrunc(reference, 2)) <= 1);
    }
    try socket.read(fds[1], &header);
    try std.testing.expectEqual(15, std.mem.readInt(u32, header[0..4], .big));
    try std.testing.expectEqual(0xffffffff, std.mem.readInt(u32, header[4..8], .big));
    var drain: [15]u8 = undefined;
    try socket.read(fds[1], &drain);
    try std.testing.expectEqualSlices(u8, "L\x00\x00\x00\x0cL\x00\x00\x00\x04L\x00\x00\x00\x11", &drain);
    try std.testing.expectError(error.ReadFailed, socket.read(fds[1], header[0..1]));
}

test "seeking in an 8 kbps stereo stream reproduces uninterrupted PCM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "low.mp3", .data = @embedFile("fixtures/low-bitrate.mp3") });
    var song = try Song.load(std.testing.allocator, std.testing.io, tmp.dir, "low.mp3");
    defer song.deinit(std.testing.allocator);
    var continuous: mp3.Decoder = .{};
    var seeking: mp3.Decoder = .{};
    var expected: [2304]i16 = undefined;
    var actual: [2304]i16 = undefined;
    try song.prime(250, &seeking, &actual);
    for (0..260) |i| {
        try song.decode(i, &continuous, &expected);
        if (i >= 250) {
            try song.decode(i, &seeking, &actual);
            const n = song.format.samples() * song.format.channels;
            try std.testing.expect(!std.mem.allEqual(i16, expected[0..n], 0));
            try std.testing.expectEqualSlices(i16, expected[0..n], actual[0..n]);
        }
    }
}

test "pause and resume remain available after all samples have been submitted" {
    const sock = @import("socket.zig");
    const fds = try @import("test_socket.zig").pair();
    defer sock.close(fds[1]);
    var p: Player = .{ .alloc = std.testing.allocator, .io = std.testing.io, .dir = .cwd(), .settings = .{ .path = "" }, .stream = .{ .fd = fds[0], .channel = 9, .credit = 0 } };
    defer p.stop();
    try p.stream.?.drain();
    try p.toggle();
    try std.testing.expect(p.paused);
    try p.toggle();
    try std.testing.expect(!p.paused);
    try std.testing.expectEqual(@as(?u32, 4), p.stream.?.drain_tag);
    try std.testing.expectEqual(7, p.stream.?.sequence);
}
