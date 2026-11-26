//! Small X11 core-protocol client. Labels mix server fonts with bundled
//! Japanese glyphs. Repaints are composed in a pixmap and copied to the window.
const std = @import("std");
const sock = @import("socket.zig");
const japanese = @import("japanese.zig");
const emoji = @import("emoji.zig");
const logo = @import("logo.zig");
const le = std.builtin.Endian.little;
fn aligned(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}
pub fn u16at(b: []const u8, i: usize) u16 {
    return std.mem.readInt(u16, b[i..][0..2], le);
}
pub fn u32at(b: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, b[i..][0..4], le);
}
fn put16(b: []u8, i: usize, n: u16) void {
    std.mem.writeInt(u16, b[i..][0..2], n, le);
}
fn put32(b: []u8, i: usize, n: u32) void {
    std.mem.writeInt(u32, b[i..][0..4], n, le);
}
fn authField(data: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* + 2 > data.len) return null;
    const len = std.mem.readInt(u16, data[pos.*..][0..2], .big);
    pos.* += 2;
    if (len > data.len - pos.*) return null;
    pos.* += len;
    return data[pos.* - len .. pos.*];
}
fn cookie(data: []const u8, display: []const u8, hostname: []const u8) []const u8 {
    var pos: usize = 0;
    var best: []const u8 = "";
    var best_score: u8 = 0;
    while (pos + 2 <= data.len) {
        const family = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;
        const address = authField(data, &pos) orelse break;
        const number = authField(data, &pos) orelse break;
        const name = authField(data, &pos) orelse break;
        const key = authField(data, &pos) orelse break;
        if (key.len != 16 or !std.mem.eql(u8, name, "MIT-MAGIC-COOKIE-1")) continue;
        if (number.len != 0 and !std.mem.eql(u8, number, display)) continue;
        const local = family == 256 and std.mem.eql(u8, address, hostname);
        if (!local and family != 65535) continue;
        const score: u8 = 1 + @as(u8, @intFromBool(local)) * 2 + @as(u8, @intFromBool(number.len != 0));
        if (score > best_score) {
            best = key;
            best_score = score;
        }
    }
    return best;
}
const Glyph = enum { capsule, left, right };

// Store fractional pixel coverage for the small transport icons at compile time.
// Rendering still uses ordinary X11 rectangles on every TrueColor display.
fn coverageMask(comptime shape: Glyph, comptime width: usize, comptime height: usize) [height][width]u8 {
    @setEvalBranchQuota(8000000);
    const w: i32 = width * 16;
    const h: i32 = height * 16;
    const radius: i32 = @divExact(@min(w, h), 2);
    var mask: [height][width]u8 = @splat(@splat(0));
    for (0..height) |row| for (0..width) |col| {
        for (0..8) |sy| for (0..8) |sx| {
            const x: i32 = @intCast(16 * col + 2 * sx + 1);
            const y: i32 = @intCast(16 * row + 2 * sy + 1);
            const inside = switch (shape) {
                .capsule => inside: {
                    const dx = x - std.math.clamp(x, radius, w - radius);
                    const dy = y - std.math.clamp(y, radius, h - radius);
                    break :inside dx * dx + dy * dy <= radius * radius;
                },
                .left, .right => (if (shape == .left) w - x else x) * h <= 2 * w * @min(y, h - y),
            };
            mask[row][col] += @intFromBool(inside);
        };
    };
    return mask;
}

fn blend(fg: u32, bg: u32, coverage: u32) u32 {
    var color: u32 = 0;
    for ([_]u5{ 16, 8, 0 }) |shift| {
        const a = fg >> shift & 255;
        const b = bg >> shift & 255;
        color |= ((a * coverage + b * (64 - coverage) + 32) / 64) << shift;
    }
    return color;
}

pub const Font = enum { normal, bold };

fn nextCodepoint(value: []const u8, pos: *usize) u21 {
    const rest = value[pos.*..];
    pos.* += 1;
    const n = std.unicode.utf8ByteSequenceLength(rest[0]) catch return 0xfffd;
    if (n > rest.len) return 0xfffd;
    const code = std.unicode.utf8Decode(rest[0..n]) catch return 0xfffd;
    pos.* += n - 1;
    return if (code < 32 or code == 127) ' ' else code;
}

const Letter = struct { code: u21 = 0, bitmap: ?*const japanese.Bitmap = null, tile: ?*const emoji.Tile = null, width: usize };

fn nextLetter(value: []const u8, pos: *usize, pitch: usize) ?Letter {
    const start = pos.*;
    var code = nextCodepoint(value, pos);
    if (code == 0xfe0e or code == 0xfe0f or code == 0x200d) {
        return null;
    }
    const icon = emoji.match(value[start..]);
    if (code >= 'ぁ' and code <= 'ヾ' and pos.* < value.len) {
        var next = pos.*;
        if (japanese.composeKana(code, nextCodepoint(value, &next))) |composed| {
            code = composed;
            pos.* = next;
        }
    }
    const bitmap = if (icon == null) japanese.lookup(code) else null;
    const advance = if (icon != null) 16 else if (bitmap == null) pitch else if (code >= 0xff61 and code <= 0xff9f) @as(usize, 8) else 16;
    if (icon) |m| pos.* = start + m.len;
    return .{ .code = code, .bitmap = bitmap, .tile = if (icon) |m| m.tile else null, .width = advance };
}

// Keep the insertion point visible in the single-line search field.
pub fn inputViewport(prefix: []const u8, width: usize) struct { start: usize, caret: usize } {
    var end: usize = 0;
    var start: usize = 0;
    var pixels: usize = 0;
    while (end < prefix.len) {
        if (nextLetter(prefix, &end, 6)) |letter| pixels += letter.width;
        while (pixels > width) {
            if (nextLetter(prefix, &start, 6)) |letter| pixels -= letter.width;
        }
    }
    return .{ .start = start, .caret = pixels };
}

pub fn inputHit(text: []const u8, x: usize) usize {
    var pos: usize = 0;
    var pixels: usize = 0;
    while (pos < text.len) {
        const start = pos;
        const letter = nextLetter(text, &pos, 6) orelse continue;
        if (pixels + letter.width / 2 > x) return start;
        pixels += letter.width;
    }
    return text.len;
}

fn fitLabel(value: []const u8, width: usize, pitch: usize, buf: *[240]Letter) []const Letter {
    var used: usize = 0;
    var pos: usize = 0;
    var n: usize = 0;
    while (pos < value.len and n < buf.len) {
        const letter = nextLetter(value, &pos, pitch) orelse {
            if (pos == value.len) return buf[0..n];
            continue;
        };
        if (letter.width > width - used) break;
        buf[n] = letter;
        used += letter.width;
        n += 1;
        if (pos == value.len) return buf[0..n];
    }
    if (width >= 3 * pitch) {
        while (n > buf.len - 3 or width - used < 3 * pitch) {
            n -= 1;
            used -= buf[n].width;
        }
        @memset(buf[n..][0..3], .{ .code = '.', .width = pitch });
        n += 3;
    }
    return buf[0..n];
}

test "mixed Japanese and Latin labels fit the column in pixels" {
    var buf: [240]Letter = undefined;
    const chars = fitLabel("A東京か\u{3099}ﾝ𠮷", 78, 6, &buf);
    try std.testing.expectEqual(6, chars.len);
    for (chars, [_]u21{ 'A', '東', '京', 'が', 'ﾝ', '𠮷' }, [_]usize{ 6, 16, 16, 16, 8, 16 }) |c, code, width| {
        try std.testing.expectEqual(code, c.code);
        try std.testing.expectEqual(width, c.width);
        try std.testing.expectEqual(code != 'A', c.bitmap != null);
    }
    const clipped = fitLabel("東京の空", 50, 6, &buf);
    try std.testing.expectEqual(5, clipped.len);
    try std.testing.expectEqual(@as(u21, '京'), clipped[1].code);
    for (clipped[2..]) |c| try std.testing.expectEqual(@as(u21, '.'), c.code);
}

test "color emoji sequences fit as one glyph alongside Japanese and emoticons" {
    var buf: [240]Letter = undefined;
    const letters = fitLabel("夜👩🏽‍🎤🇯🇵1️⃣❤️:-)", 98, 6, &buf);
    try std.testing.expectEqual(8, letters.len);
    try std.testing.expect(letters[0].bitmap != null);
    for (letters[1..5]) |letter| {
        try std.testing.expect(letter.tile != null);
        try std.testing.expectEqual(16, letter.width);
    }
    for (letters[5..], ":-)") |letter, ascii| try std.testing.expectEqual(ascii, letter.code);
    const clipped = fitLabel("👩🏽‍🎤🇯🇵🎶🎶", 34, 6, &buf);
    try std.testing.expectEqual(4, clipped.len);
    try std.testing.expect(clipped[0].tile != null);
    for (clipped[1..]) |letter| try std.testing.expectEqual(@as(u21, '.'), letter.code);
    const text_heart = fitLabel("♥\u{fe0e}", 6, 6, &buf);
    try std.testing.expectEqual(1, text_heart.len);
    try std.testing.expect(text_heart[0].tile == null);
}

const Event = struct {
    header: [32]u8,
    // The only non-keyboard reply after startup is a bounded clipboard property.
    data: [@import("search.zig").Input.capacity]u8 = undefined,

    fn readBody(e: *Event, fd: sock.Fd) !void {
        if (e.header[0] != 1) return;
        const words = u32at(&e.header, 4);
        if (words > e.data.len / 4) return error.InvalidDisplay;
        try sock.read(fd, e.data[0 .. words * 4]);
    }
};

pub const Display = struct {
    fd: sock.Fd,
    base: u32,
    window: u32,
    gc: u32,
    pixmap: u32,
    depth: u8,
    width: u16 = 900,
    height: u16 = 600,
    delete_atom: u32 = 0,
    protocols: u32 = 0,
    name_atom: u32 = 0,
    utf8_atom: u32 = 0,
    font_normal: u32,
    font_bold: u32,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    pending: std.ArrayList(Event) = .empty,
    pending_pos: usize = 0,
    sequence: u16 = 0,
    keys: [256][8]u32 = @splat(@splat(0)),
    clipboard: u32 = 0,
    buffer: [32768]u8 = undefined,
    used: usize = 0,
    color: u32 = 0xffffffff,
    font_id: u32 = 0,
    masks: [3]u32 = .{ 0xff0000, 0xff00, 0xff },

    pub fn open(init: std.process.Init) !Display {
        const env = init.environ_map;
        const alloc = init.arena.allocator();
        var display = env.get("DISPLAY") orelse return error.DisplayNotSet;
        if (std.mem.startsWith(u8, display, "unix:")) display = display[4..];
        if (display.len < 2 or display[0] != ':') return error.LocalDisplayRequired;
        var parts = std.mem.splitScalar(u8, display[1..], '.');
        const number = parts.next().?;
        _ = std.fmt.parseInt(u16, number, 10) catch return error.InvalidDisplay;
        const screen = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch return error.InvalidDisplay;
        const path = try std.fmt.allocPrint(alloc, "/tmp/.X11-unix/X{s}", .{number});
        const fd = sock.connect(path) catch return error.CannotConnectToDisplay;
        errdefer sock.close(fd);
        const auth_path = env.get("XAUTHORITY") orelse try std.fs.path.join(alloc, &.{ env.get("HOME") orelse ".", ".Xauthority" });
        const data = std.Io.Dir.cwd().readFileAlloc(init.io, auth_path, alloc, .limited(1024 * 1024)) catch "";
        var uts: sock.linux.utsname = undefined;
        const hostname = env.get("XAUTHLOCALHOSTNAME") orelse if (sock.linux.errno(sock.linux.uname(&uts)) == .SUCCESS) std.mem.sliceTo(&uts.nodename, 0) else "";
        const key = cookie(data, number, hostname);
        const name: []const u8 = if (key.len != 0) "MIT-MAGIC-COOKIE-1" else "";
        var hello: [48]u8 = @splat(0);
        hello[0] = 'l';
        put16(&hello, 2, 11);
        put16(&hello, 6, @intCast(name.len));
        put16(&hello, 8, @intCast(key.len));
        @memcpy(hello[12..][0..name.len], name);
        @memcpy(hello[12 + aligned(name.len) ..][0..key.len], key);
        try sock.write(fd, hello[0 .. 12 + aligned(name.len) + aligned(key.len)]);
        var head: [8]u8 = undefined;
        try sock.read(fd, &head);
        if (head[0] != 1) return error.DisplayAuthorizationFailed;
        const setup = try alloc.alloc(u8, @as(usize, u16at(&head, 6)) * 4);
        try sock.read(fd, setup);
        if (setup.len < 32 or screen >= setup[20]) return error.InvalidDisplay;
        const base = u32at(setup, 4);
        var offset = 32 + aligned(u16at(setup, 16)) + @as(usize, setup[21]) * 8;
        var self: Display = .{ .allocator = init.gpa, .fd = fd, .base = base, .window = base + 1, .gc = base + 2, .pixmap = base + 3, .font_normal = base + 4, .font_bold = base + 5, .depth = 0 };
        var root: u32 = 0;
        for (0..@as(usize, screen) + 1) |_| {
            if (offset + 40 > setup.len) return error.InvalidDisplay;
            const s = setup[offset..][0..40];
            offset += 40;
            root = u32at(s, 0);
            self.depth = s[38];
            const visual = u32at(s, 32);
            for (0..s[39]) |_| {
                if (offset + 8 > setup.len) return error.InvalidDisplay;
                const count = u16at(setup, offset + 2);
                offset += 8;
                for (0..count) |_| {
                    if (offset + 24 > setup.len) return error.InvalidDisplay;
                    const v = setup[offset..][0..24];
                    offset += 24;
                    if (u32at(v, 0) == visual) self.masks = .{ u32at(v, 8), u32at(v, 12), u32at(v, 16) };
                }
            }
        }
        if (self.depth < 15) return error.TrueColorDisplayRequired;
        const low = setup[26];
        const high = setup[27];
        if (low == 0 or low > high) return error.InvalidDisplay;
        errdefer self.pending.deinit(self.allocator);
        try self.refreshKeys(low, high - low + 1);
        self.protocols = try self.atom("WM_PROTOCOLS");
        self.delete_atom = try self.atom("WM_DELETE_WINDOW");
        self.name_atom = try self.atom("_NET_WM_NAME");
        self.utf8_atom = try self.atom("UTF8_STRING");
        self.clipboard = try self.atom("CLIPBOARD");
        const w = try self.req(1, 0, 40);
        put32(w, 4, self.window);
        put32(w, 8, root);
        put16(w, 16, self.width);
        put16(w, 18, self.height);
        put16(w, 22, 1);
        put32(w, 28, 2 | 2048);
        put32(w, 32, self.pixel(@import("theme.zig").canvas));
        put32(w, 36, 1 | 4 | (1 << 15) | (1 << 17)); // key, mouse, expose, structure
        try self.setTitle(null);
        try self.setIcon();
        try self.property(67, 31, 8, "ampz\x00Ampz\x00"); // WM_CLASS
        var atom_data: [4]u8 = undefined;
        put32(&atom_data, 0, self.delete_atom);
        try self.property(self.protocols, 4, 32, &atom_data);
        var hints: [72]u8 = @splat(0);
        put32(&hints, 0, 1 << 4);
        put32(&hints, 20, 560);
        put32(&hints, 24, 420);
        try self.property(40, 41, 32, &hints);
        // Prefer Unicode bitmap fonts so international tags use their codepoints.
        const normal_pattern = "-misc-fixed-medium-r-*-*-13-*-*-*-c-60-iso10646-1";
        const bold_pattern = "-misc-fixed-bold-r-*-*-15-*-*-*-c-90-iso10646-1";
        try self.openFont(self.font_normal, if (try self.fontExists(normal_pattern)) normal_pattern else "fixed");
        const boldname = if (try self.fontExists(bold_pattern)) bold_pattern else if (try self.fontExists("9x15bold")) "9x15bold" else "fixed";
        try self.openFont(self.font_bold, boldname);
        const gc = try self.req(55, 0, 20);
        put32(gc, 4, self.gc);
        put32(gc, 8, self.window);
        put32(gc, 12, 1 << 16);
        put32(gc, 16, 0);
        try self.makePixmap();
        const map = try self.req(8, 0, 8);
        put32(map, 4, self.window);
        try self.flush();
        return self;
    }
    pub fn close(d: *Display) void {
        d.pending.deinit(d.allocator);
        sock.close(d.fd);
    }
    fn req(d: *Display, opcode: u8, detail: u8, size: usize) ![]u8 {
        const n = aligned(size);
        if (n > d.buffer.len - d.used) try d.flush();
        const b = d.buffer[d.used..][0..n];
        d.used += n;
        @memset(b, 0);
        d.sequence +%= 1;
        b[0] = opcode;
        b[1] = detail;
        put16(b, 2, @intCast(n / 4));
        return b;
    }
    fn flush(d: *Display) !void {
        try sock.write(d.fd, d.buffer[0..d.used]);
        d.used = 0;
    }
    fn reply(d: *Display) ![32]u8 {
        try d.flush();
        var b: [32]u8 = undefined;
        // Synchronous queries only occur before MapWindow.
        while (true) {
            try sock.read(d.fd, &b);
            switch (b[0]) {
                0 => return error.X11RequestFailed,
                1 => return b,
                else => {},
            }
        }
    }
    fn atom(d: *Display, name: []const u8) !u32 {
        const b = try d.req(16, 0, 8 + name.len);
        put16(b, 4, @intCast(name.len));
        @memcpy(b[8..][0..name.len], name);
        const r = try d.reply();
        return u32at(&r, 8);
    }
    fn property(d: *Display, prop: u32, kind: u32, format: u8, value: []const u8) !void {
        const b = try d.req(18, 0, 24 + value.len);
        put32(b, 4, d.window);
        put32(b, 8, prop);
        put32(b, 12, kind);
        b[16] = format;
        put32(b, 20, @intCast(value.len / (format / 8)));
        @memcpy(b[24..][0..value.len], value);
    }
    pub fn setTitle(d: *Display, song: ?[]const u8) !void {
        var utf8: [4096]u8 = undefined;
        var legacy: [4096]u8 = undefined;
        var bytes: usize = 0;
        var latin: usize = 0;
        const text = song orelse "ampz";
        var pos: usize = 0;
        while (pos < text.len) {
            const code = nextCodepoint(text, &pos);
            var encoded: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(code, &encoded);
            if (n > utf8.len - bytes) break;
            @memcpy(utf8[bytes..][0..n], encoded[0..n]);
            bytes += n;
            legacy[latin] = if (code <= 255) @intCast(code) else '?';
            latin += 1;
        }
        try d.property(39, 31, 8, legacy[0..latin]); // WM_NAME, STRING
        try d.property(d.name_atom, d.utf8_atom, 8, utf8[0..bytes]);
    }
    pub fn nextEvent(d: *Display) !Event {
        if (d.pending_pos < d.pending.items.len) {
            const e = d.pending.items[d.pending_pos];
            d.pending_pos += 1;
            if (d.pending_pos == d.pending.items.len) {
                d.pending.clearRetainingCapacity();
                d.pending_pos = 0;
            }
            return e;
        }
        var e: Event = undefined;
        try sock.read(d.fd, &e.header);
        try e.readBody(d.fd);
        return e;
    }

    pub fn refreshKeys(d: *Display, first: u8, count: u8) !void {
        if (count == 0) return;
        const end = @as(usize, first) + count;
        if (end > d.keys.len) return error.InvalidDisplay;
        const request = try d.req(101, 0, 8); // GetKeyboardMapping
        request[4] = first;
        request[5] = count;
        try d.flush();
        while (true) {
            var e: Event = undefined;
            try sock.read(d.fd, &e.header);
            if (e.header[0] == 0) return error.X11RequestFailed;
            if (e.header[0] == 1 and u16at(&e.header, 2) == d.sequence) {
                const per = e.header[1];
                if (per == 0 or u32at(&e.header, 4) != @as(u32, count) * per) return error.InvalidDisplay;
                var row: [255 * 4]u8 = undefined;
                for (d.keys[first..end]) |*levels| {
                    try sock.read(d.fd, row[0 .. @as(usize, per) * 4]);
                    levels.* = @splat(0);
                    for (0..@min(levels.len, per)) |i| levels[i] = u32at(&row, i * 4);
                }
                return;
            }
            // Preserve keypresses and outstanding clipboard replies in wire order.
            try e.readBody(d.fd);
            try d.pending.append(d.allocator, e);
        }
    }

    pub fn keySym(d: *const Display, code: u8, state: u16) u32 {
        const levels = d.keys[code];
        var group: usize = if (state & 0x6000 != 0 and levels[2] != 0) 2 else 0;
        if (state & 0x80 != 0) {
            if (levels[group + 4] != 0) group += 4 else if (levels[2] != 0) group = 2;
        }
        const base = levels[group];
        const upper = levels[group + 1];
        var shifted = state & 1 != 0;
        if (base >= 'a' and base <= 'z' and state & 2 != 0) shifted = !shifted;
        if (!shifted) return base;
        if (upper != 0) return upper;
        return if (base >= 'a' and base <= 'z') base - 32 else base;
    }

    pub fn requestPaste(d: *Display, time: u32) !void {
        const b = try d.req(24, 0, 24); // ConvertSelection
        put32(b, 4, d.window);
        put32(b, 8, d.clipboard);
        put32(b, 12, d.utf8_atom);
        put32(b, 16, 9); // CUT_BUFFER0 on our own window
        put32(b, 20, time);
        try d.flush();
    }

    pub fn requestPasteData(d: *Display, limit: usize) !void {
        const b = try d.req(20, 1, 24); // GetProperty, delete after reading
        put32(b, 4, d.window);
        put32(b, 8, 9);
        put32(b, 12, d.utf8_atom);
        put32(b, 20, @intCast((limit + 3) / 4));
        try d.flush();
    }

    fn setIcon(d: *Display) !void {
        const prop = try d.atom("_NET_WM_ICON");
        try d.property(prop, 6, 32, &logo.icon); // CARDINAL
    }
    fn fontExists(d: *Display, name: []const u8) !bool {
        const b = try d.req(49, 0, 8 + name.len);
        put16(b, 4, 1);
        put16(b, 6, @intCast(name.len));
        @memcpy(b[8..][0..name.len], name);
        const r = try d.reply();
        const count = u32at(&r, 4) * 4;
        var buf: [260]u8 = undefined;
        if (count > buf.len) return error.InvalidDisplay;
        try sock.read(d.fd, buf[0..count]);
        return u16at(&r, 8) > 0;
    }
    fn openFont(d: *Display, id: u32, name: []const u8) !void {
        const b = try d.req(45, 0, 12 + name.len);
        put32(b, 4, id);
        put16(b, 8, @intCast(name.len));
        @memcpy(b[12..][0..name.len], name);
    }
    fn makePixmap(d: *Display) !void {
        const b = try d.req(53, d.depth, 16);
        put32(b, 4, d.pixmap);
        put32(b, 8, d.window);
        put16(b, 12, d.width);
        put16(b, 14, d.height);
    }
    pub fn resize(d: *Display, width: u16, height: u16) !void {
        if (width == d.width and height == d.height) return;
        const b = try d.req(54, 0, 8);
        put32(b, 4, d.pixmap);
        d.width = width;
        d.height = height;
        try d.makePixmap();
    }
    fn pixel(d: *Display, color: u32) u32 {
        var result: u32 = 0;
        for (d.masks, [_]u5{ 16, 8, 0 }) |mask, shift| {
            if (mask == 0) continue;
            const low: u5 = @intCast(@ctz(mask));
            result |= (((color >> shift & 255) * (mask >> low) / 255) << low) & mask;
        }
        return result;
    }
    fn ink(d: *Display, color: u32) !void {
        if (d.color == color) return;
        const b = try d.req(56, 0, 16);
        put32(b, 4, d.gc);
        put32(b, 8, 4);
        put32(b, 12, d.pixel(color));
        d.color = color;
    }
    pub fn rect(d: *Display, x: usize, y: usize, width: usize, height: usize, color: u32) !void {
        if (width == 0 or height == 0 or x >= d.width or y >= d.height) return;
        try d.ink(color);
        const b = try d.req(70, 0, 20);
        put32(b, 4, d.pixmap);
        put32(b, 8, d.gc);
        put16(b, 12, @intCast(x));
        put16(b, 14, @intCast(y));
        put16(b, 16, @intCast(@min(width, d.width - x)));
        put16(b, 18, @intCast(@min(height, d.height - y)));
    }
    pub fn glyph(d: *Display, comptime shape: Glyph, x: usize, y: usize, comptime width: usize, comptime height: usize, fg: u32, bg: u32) !void {
        const mask = comptime coverageMask(shape, width, height);
        for (&mask, 0..) |*row, dy| {
            var col: usize = 0;
            while (col < width) {
                const start = col;
                const coverage = row[col];
                col += 1;
                while (col < width and row[col] == coverage) col += 1;
                if (coverage != 0) try d.rect(x + start, y + dy, col - start, 1, blend(fg, bg, coverage));
            }
        }
    }
    fn bitmapChar(d: *Display, x: usize, y: usize, bitmap: *const japanese.Bitmap) !void {
        var points: [16 * 16 * 4]u8 = undefined;
        var len: usize = 0;
        for (0..16) |row| {
            if (y + row < 14 or y + row - 14 >= d.height) continue;
            const pixels = std.mem.readInt(u16, bitmap[row * 2 ..][0..2], .big);
            for (0..16) |col| {
                if (pixels & (@as(u16, 0x8000) >> @intCast(col)) == 0) continue;
                put16(&points, len, @intCast(x + col));
                put16(&points, len + 2, @intCast(y + row - 14));
                len += 4;
            }
        }
        if (len == 0) return;
        try d.drawPoints(points[0..len]);
    }
    fn drawPoints(d: *Display, points: []const u8) !void {
        const req_data = try d.req(64, 0, 12 + points.len); // PolyPoint, absolute coordinates
        put32(req_data, 4, d.pixmap);
        put32(req_data, 8, d.gc);
        @memcpy(req_data[12..][0..points.len], points);
    }
    fn textRun(d: *Display, x: usize, y: usize, font: Font, chars: []const Letter) !void {
        const id = if (font == .bold) d.font_bold else d.font_normal;
        if (d.font_id != id) {
            const b = try d.req(56, 0, 16);
            put32(b, 4, d.gc);
            put32(b, 8, 1 << 14);
            put32(b, 12, id);
            d.font_id = id;
        }
        const b = try d.req(75, 0, 18 + chars.len * 2);
        put32(b, 4, d.pixmap);
        put32(b, 8, d.gc);
        put16(b, 12, @intCast(x));
        put16(b, 14, @intCast(y));
        b[16] = @intCast(chars.len);
        for (chars, 0..) |c, i| {
            std.mem.writeInt(u16, b[18 + i * 2 ..][0..2], if (c.code <= 65535) @intCast(c.code) else '?', .big);
        }
    }
    fn emojiChar(d: *Display, x: usize, y: usize, tile: *const emoji.Tile) !void {
        for (1..16) |index| {
            var points: [256 * 4]u8 = undefined;
            var len: usize = 0;
            for (tile[45..], 0..) |pair, i| {
                for ([2]u8{ pair >> 4, pair & 15 }, 0..) |color, half| {
                    if (color != index) continue;
                    const pixel_index = 2 * i + half;
                    const row = y + pixel_index / 16;
                    if (row < 14 or row - 14 >= d.height) continue;
                    put16(&points, len, @intCast(x + pixel_index % 16));
                    put16(&points, len + 2, @intCast(row - 14));
                    len += 4;
                }
            }
            if (len == 0) continue;
            try d.ink(std.mem.readInt(u24, tile[3 * (index - 1) ..][0..3], .big));
            try d.drawPoints(points[0..len]);
        }
    }
    pub fn label(d: *Display, x: usize, y: usize, width: usize, color: u32, font: Font, value: []const u8) !void {
        if (x >= d.width or y > d.height or value.len == 0) return;
        const pitch: usize = if (font == .bold) 9 else 6;
        var buffer: [240]Letter = undefined;
        const chars = fitLabel(value, @min(width, d.width - x), pitch, &buffer);
        var pos = x;
        var i: usize = 0;
        while (i < chars.len) {
            if (chars[i].tile) |tile| {
                try d.emojiChar(pos, y, tile);
                pos += chars[i].width;
                i += 1;
            } else if (chars[i].bitmap) |bitmap| {
                try d.ink(color);
                try d.bitmapChar(pos, y, bitmap);
                pos += chars[i].width;
                i += 1;
            } else {
                const start = i;
                while (i < chars.len and chars[i].bitmap == null and chars[i].tile == null) i += 1;
                try d.ink(color);
                try d.textRun(pos, y, font, chars[start..i]);
                pos += (i - start) * pitch;
            }
        }
    }
    pub fn present(d: *Display) !void {
        const b = try d.req(62, 0, 28);
        put32(b, 4, d.pixmap);
        put32(b, 8, d.window);
        put32(b, 12, d.gc);
        put16(b, 24, d.width);
        put16(b, 26, d.height);
        try d.flush();
    }
};

test "window icon publishes the Playhead mark as 32-bit ARGB" {
    const fds = try @import("test_socket.zig").pair();
    defer sock.close(fds[0]);
    defer sock.close(fds[1]);
    var d: Display = .{ .fd = fds[0], .base = 1, .window = 2, .gc = 3, .pixmap = 4, .depth = 24, .font_normal = 5, .font_bold = 6 };
    var atom_reply: [32]u8 = @splat(0);
    atom_reply[0] = 1;
    put32(&atom_reply, 8, 123);
    try sock.write(fds[1], &atom_reply);
    try d.setIcon();
    var query: [20]u8 = undefined;
    try sock.read(fds[1], &query);
    try std.testing.expectEqual(16, query[0]); // InternAtom
    try std.testing.expectEqualStrings("_NET_WM_ICON", query[8..]);

    const request = d.buffer[0..d.used];
    try std.testing.expectEqual(18, request[0]); // ChangeProperty
    try std.testing.expectEqual(d.window, u32at(request, 4));
    try std.testing.expectEqual(123, u32at(request, 8));
    try std.testing.expectEqual(6, u32at(request, 12)); // CARDINAL
    try std.testing.expectEqual(32, request[16]);
    try std.testing.expectEqual(1026, u32at(request, 20));
    try std.testing.expectEqual(32, u32at(request, 24));
    try std.testing.expectEqual(32, u32at(request, 28));
    const pixels = request[32..];
    try std.testing.expectEqual(4096, pixels.len);
    const Sample = struct { x: usize, y: usize, argb: u32 };
    for ([_]Sample{
        .{ .x = 0, .y = 0, .argb = 0 }, // Transparent tile corner
        .{ .x = 16, .y = 8, .argb = 0xffffab85 }, // Top of the A
        .{ .x = 16, .y = 15, .argb = 0xff242c2b }, // Play cutout
        .{ .x = 20, .y = 15, .argb = 0xffffab85 }, // Beyond its tip
        .{ .x = 7, .y = 24, .argb = 0xffffab85 }, // Left foot
        .{ .x = 16, .y = 24, .argb = 0xff242c2b }, // Gap
        .{ .x = 24, .y = 24, .argb = 0xffffab85 }, // Right foot
    }) |sample| {
        try std.testing.expectEqual(sample.argb, u32at(pixels, 4 * (sample.y * 32 + sample.x)));
    }
}

test "local Xauthority entries match host and display ahead of wildcard records" {
    const other = "\x01\x00\x00\x05other\x00\x010";
    const local = "\x01\x00\x00\x05local\x00\x010";
    const wild = "\xff\xff\x00\x00\x00\x00";
    const auth = "\x00\x12MIT-MAGIC-COOKIE-1\x00\x10";
    const records = other ++ auth ++ "aaaaaaaaaaaaaaaa" ++ wild ++ auth ++ "bbbbbbbbbbbbbbbb" ++ local ++ auth ++ "cccccccccccccccc";
    try std.testing.expectEqualStrings("cccccccccccccccc", cookie(records, "0", "local"));
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbb", cookie(records, "1", "local"));
    try std.testing.expectEqualStrings("", cookie(other ++ auth ++ "aaaaaaaaaaaaaaaa", "0", "local"));
}

test "keymap refresh preserves a clipboard reply and keys pressed during a layout change" {
    const fds = try @import("test_socket.zig").pair();
    defer sock.close(fds[1]);
    var display: Display = .{ .allocator = std.testing.allocator, .fd = fds[0], .base = 1, .window = 2, .gc = 3, .pixmap = 4, .depth = 24, .font_normal = 5, .font_bold = 6 };
    defer display.close();
    display.keys[38][0] = 'a';
    display.keys[38][1] = 'A';
    display.sequence = 9;
    var clipboard: [32]u8 = @splat(0);
    clipboard[0] = 1;
    put16(&clipboard, 2, 9);
    put32(&clipboard, 4, 1);
    try sock.write(fds[1], &clipboard);
    try sock.write(fds[1], "text");
    var press: [32]u8 = @splat(0);
    press[0] = 2;
    press[1] = 38;
    try sock.write(fds[1], &press);
    var mapping: [32]u8 = @splat(0);
    mapping[0] = 1;
    mapping[1] = 1;
    put16(&mapping, 2, 10);
    put32(&mapping, 4, 1);
    try sock.write(fds[1], &mapping);
    var value: [4]u8 = undefined;
    put32(&value, 0, 0x6c6);
    try sock.write(fds[1], &value);
    try display.refreshKeys(38, 1);
    const saved = try display.nextEvent();
    try std.testing.expectEqualStrings("text", saved.data[0..4]);
    const event = try display.nextEvent();
    try std.testing.expectEqual(2, event.header[0]);
    try std.testing.expectEqual(0x6c6, display.keySym(event.header[1], 0));
    try std.testing.expectEqual(0, display.keys[38][1]);
    try std.testing.expectEqual(0, display.pending.items.len);
}
