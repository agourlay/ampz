//! Pulse native protocol v8. The server requests PCM bytes as its buffer empties.
const std = @import("std");
const socket = @import("socket.zig");
const control = std.math.maxInt(u32);
const Command = enum(u32) { failure = 0, reply = 2, create = 3, auth = 8, name = 9, drain = 12, cork = 41, request = 61, killed = 64, _ };
const Packet = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    fn bytes(p: *Packet, data: []const u8) void {
        @memcpy(p.buf[p.len..][0..data.len], data);
        p.len += data.len;
    }
    fn byte(p: *Packet, n: u8) void {
        p.buf[p.len] = n;
        p.len += 1;
    }
    fn raw(p: *Packet, n: u32) void {
        std.mem.writeInt(u32, p.buf[p.len..][0..4], n, .big);
        p.len += 4;
    }
    fn uint(p: *Packet, n: u32) void {
        p.byte('L');
        p.raw(n);
    }
    fn string(p: *Packet, s: []const u8) void {
        p.byte('t');
        p.bytes(s);
        p.byte(0);
    }
    fn init(cmd: Command, tag: u32) Packet {
        var p: Packet = .{};
        p.uint(@backingInt(cmd));
        p.uint(tag);
        return p;
    }
    fn send(p: *const Packet, fd: socket.Fd) !void {
        try sendPacket(fd, control, p.buf[0..p.len]);
    }
};
fn sendPacket(fd: socket.Fd, channel: u32, payload: []const u8) !void {
    var header: [20]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], @intCast(payload.len), .big);
    std.mem.writeInt(u32, header[4..8], channel, .big);
    try socket.write(fd, &header);
    try socket.write(fd, payload);
}
const Message = struct {
    buf: [4096]u8 = undefined,
    pos: usize = 0,
    len: usize,
    fn receive(fd: socket.Fd) !Message {
        var header: [20]u8 = undefined;
        try socket.read(fd, &header);
        var msg: Message = .{ .len = std.mem.readInt(u32, header[0..4], .big) };
        if (msg.len > msg.buf.len or std.mem.readInt(u32, header[4..8], .big) != control) return error.InvalidSoundReply;
        try socket.read(fd, msg.buf[0..msg.len]);
        return msg;
    }
    fn uint(m: *Message) !u32 {
        if (m.pos + 5 > m.len or m.buf[m.pos] != 'L') return error.InvalidSoundReply;
        const v = std.mem.readInt(u32, m.buf[m.pos + 1 ..][0..4], .big);
        m.pos += 5;
        return v;
    }
    fn reply(fd: socket.Fd, tag: u32) !Message {
        var m = try receive(fd);
        if (try m.uint() != @backingInt(Command.reply) or try m.uint() != tag) return error.SoundRequestRejected;
        return m;
    }
};
fn cookiePath(alloc: std.mem.Allocator, explicit: ?[]const u8, xdg: ?[]const u8, home: ?[]const u8) !?[]const u8 {
    if (explicit) |path| return path;
    if (xdg) |dir| {
        if (std.fs.path.isAbsolute(dir)) return try std.fs.path.join(alloc, &.{ dir, "pulse/cookie" });
    }
    return try std.fs.path.join(alloc, &.{ home orelse return null, ".config/pulse/cookie" });
}

test "explicit PulseAudio cookie takes precedence without HOME" {
    try std.testing.expectEqualStrings("/custom", (try cookiePath(std.testing.allocator, "/custom", "/other", null)).?);
    const path = (try cookiePath(std.testing.allocator, null, "/prefs", null)).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/prefs/pulse/cookie", path);
}

pub const Settings = struct {
    path: []const u8,
    cookie: [256]u8 = @splat(0),
    pub fn init(init_args: std.process.Init) !Settings {
        const env = init_args.environ_map;
        const alloc = init_args.arena.allocator();
        const runtime = env.get("XDG_RUNTIME_DIR") orelse try std.fmt.allocPrint(alloc, "/run/user/{d}", .{socket.linux.getuid()});
        const path = if (env.get("PULSE_SERVER")) |s| (if (std.mem.startsWith(u8, s, "unix:")) s[5..] else s) else try std.fs.path.join(alloc, &.{ runtime, "pulse/native" });
        var settings: Settings = .{ .path = path };
        const cookie_path = (try cookiePath(alloc, env.get("PULSE_COOKIE"), env.get("XDG_CONFIG_HOME"), env.get("HOME"))) orelse return settings;
        const cookie = std.Io.Dir.cwd().readFile(init_args.io, cookie_path, &settings.cookie) catch return settings;
        if (cookie.len != 256) settings.cookie = @splat(0);
        return settings;
    }
};
pub const Stream = struct {
    fd: socket.Fd,
    channel: u32,
    credit: usize,
    finished: bool = false,
    drain_tag: ?u32 = null,
    sequence: u32 = 4,
    pub fn open(settings: *const Settings, rate: u32, channels: usize) !Stream {
        const fd = try socket.connect(settings.path);
        errdefer socket.close(fd);
        var auth = Packet.init(.auth, 1);
        auth.uint(8);
        auth.byte('x');
        auth.raw(256);
        auth.bytes(&settings.cookie);
        try auth.send(fd);
        _ = try Message.reply(fd, 1);
        var name = Packet.init(.name, 2);
        name.string("ampz");
        try name.send(fd);
        _ = try Message.reply(fd, 2);
        var create = Packet.init(.create, 3);
        create.string("Music");
        const count: u8 = @intCast(channels);
        create.bytes(&.{ 'a', 3, count });
        create.raw(rate); // PA_SAMPLE_S16LE
        create.bytes(&.{ 'm', count });
        if (count == 1) create.byte(0) else create.bytes(&.{ 1, 2 });
        create.uint(control);
        create.byte('N'); // default sink
        const chunk = rate / 25 * count * 2;
        create.uint(chunk * 8);
        create.byte('0');
        create.uint(chunk * 4);
        create.uint(chunk);
        create.uint(chunk);
        create.uint(0);
        create.bytes(&.{ 'v', count });
        for (0..count) |_| create.raw(65536);
        try create.send(fd);
        var m = try Message.reply(fd, 3);
        const channel = try m.uint();
        _ = try m.uint();
        return .{ .fd = fd, .channel = channel, .credit = try m.uint() };
    }
    pub fn close(s: *Stream) void {
        socket.close(s.fd);
    }
    pub fn event(s: *Stream) !void {
        var m = try Message.receive(s.fd);
        const cmd: Command = @fromBackingInt(@intCast(try m.uint()));
        const tag = try m.uint();
        switch (cmd) {
            .request => {
                if (try m.uint() != s.channel) return error.InvalidSoundReply;
                s.credit += try m.uint();
            },
            .reply => if (s.drain_tag == tag) {
                s.finished = true;
            },
            .failure, .killed => return error.SoundStreamEnded,
            else => {},
        }
    }
    pub fn write(s: *Stream, bytes: []const u8) !void {
        try sendPacket(s.fd, s.channel, bytes);
        s.credit -= bytes.len;
    }
    pub fn pause(s: *Stream, paused: bool) !void {
        var packet = Packet.init(.cork, s.sequence);
        s.sequence +%= 1;
        packet.uint(s.channel);
        packet.byte(if (paused) '1' else '0');
        try packet.send(s.fd);
    }
    pub fn drain(s: *Stream) !void {
        var packet = Packet.init(.drain, s.sequence);
        s.sequence +%= 1;
        packet.uint(s.channel);
        try packet.send(s.fd);
        s.drain_tag = s.sequence -% 1;
    }
};

test "only the matching drain reply finishes the stream" {
    const fds = try @import("test_socket.zig").pair();
    defer socket.close(fds[0]);
    defer socket.close(fds[1]);
    var stream: Stream = .{ .fd = fds[0], .channel = 9, .credit = 0 };
    try stream.pause(true);
    try stream.drain();
    try stream.pause(false);
    const reply_header = "\x00\x00\x00\x0a" ++ "\xff\xff\xff\xff" ++ @as([12]u8, @splat(0));
    try socket.write(fds[1], reply_header ++ "L\x00\x00\x00\x02L\x00\x00\x00\x04");
    try stream.event();
    try std.testing.expect(!stream.finished);
    try socket.write(fds[1], reply_header ++ "L\x00\x00\x00\x02L\x00\x00\x00\x05");
    try stream.event();
    try std.testing.expect(stream.finished);
}
