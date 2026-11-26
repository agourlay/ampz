const std = @import("std");
const X = @import("x11.zig");
const Display = X.Display;
const Track = @import("library.zig").Track;
const Player = @import("player.zig").Player;
const sock = @import("socket.zig");
const logo = @import("logo.zig");
const search = @import("search.zig");
const theme = @import("theme.zig");
const row_h = 31;
const header_h = 53;
const Rect = struct {
    x: usize,
    y: usize,
    w: usize,
    h: usize,

    fn hit(r: Rect, x: usize, y: usize, padding: usize) bool {
        return x >= r.x -| padding and x < r.x + r.w + padding and
            y >= r.y -| padding and y < r.y + r.h + padding;
    }
};
const previous_button: Rect = .{ .x = 22, .y = 34, .w = 16, .h = 14 };
const play_button: Rect = .{ .x = 51, .y = 19, .w = 44, .h = 44 };
const next_button: Rect = .{ .x = 108, .y = 34, .w = 16, .h = 14 };

fn scalePosition(position: usize, from: usize, to: usize) usize {
    return @intCast(std.math.mulWide(usize, position, to) / from);
}

test "progress and seek scale at full sample precision" {
    const samples = 4 * 60 * 44100;
    try std.testing.expectEqual(462, scalePosition(samples * 3 / 4, samples, 617));
    try std.testing.expectEqual(10566846, scalePosition(616, 617, samples));
    try std.testing.expectEqual(samples, scalePosition(617, 617, samples));
    try std.testing.expectEqual(617, scalePosition(std.math.maxInt(usize), std.math.maxInt(usize), 617));
}

test "transport buttons accept clicks near their glyphs" {
    for ([_]Rect{ previous_button, play_button, next_button }) |button| {
        const x = button.x + button.w / 2;
        try std.testing.expect(button.hit(x, button.y + button.h / 2, 4));
        try std.testing.expect(!button.hit(x, 2, 6));
        try std.testing.expect(!button.hit(x, 80, 6));
    }
}

const Pane = enum(usize) { artists, albums, tracks };
const Layout = struct {
    w: usize,
    h: usize,
    side: usize,
    split: usize,
    bottom: usize,
    fn make(d: *const Display) Layout {
        const w: usize = @max(560, d.width);
        const h: usize = @max(420, d.height);
        return .{ .w = w, .h = h, .side = @min(244, w / 4), .split = header_h + (h - header_h - 84) / 2, .bottom = h - 84 };
    }
    fn start(l: Layout, p: Pane) usize {
        return switch (p) {
            .artists => header_h + 39,
            .albums => l.split + 39,
            .tracks => header_h + 68,
        };
    }
    fn searchBox(l: Layout) Rect {
        return .{ .x = 125, .y = 10, .w = @min(440, l.w - 235), .h = 33 };
    }
    fn rows(l: Layout, p: Pane) usize {
        return ((if (p == .artists) l.split else l.bottom) - l.start(p)) / row_h;
    }
};
fn byName(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}
const View = struct {
    alloc: std.mem.Allocator,
    tracks: []const Track,
    artists: std.ArrayList([]const u8) = .empty,
    albums: std.ArrayList([]const u8) = .empty,
    visible: std.ArrayList(usize) = .empty,
    query: search.Input = .{},
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    selected: usize = 0,
    scroll: [3]usize = @splat(0),
    fn names(v: *View, comptime field: []const u8, list: *std.ArrayList([]const u8)) !void {
        list.clearRetainingCapacity();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(v.alloc);
        for (v.tracks) |t| {
            if (comptime std.mem.eql(u8, field, "album")) if (v.artist) |a| {
                if (!t.hasArtist(a)) continue;
            };
            const values = if (comptime std.mem.eql(u8, field, "artist")) t.artistNames() else (&t.album)[0..1];
            for (values) |value| {
                const entry = try seen.getOrPut(v.alloc, value);
                if (!entry.found_existing) try list.append(v.alloc, value);
            }
        }
        std.mem.sort([]const u8, list.items, {}, byName);
    }
    fn filter(v: *View) !void {
        v.visible.clearRetainingCapacity();
        for (v.tracks, 0..) |t, i| {
            if (v.artist) |a| {
                if (!t.hasArtist(a)) continue;
            }
            if (v.album) |a| {
                if (!std.mem.eql(u8, a, t.album)) continue;
            }
            if (!search.matches(&t, v.query.text())) continue;
            try v.visible.append(v.alloc, i);
        }
        v.selected = 0;
        v.scroll[2] = 0;
    }
    fn total(v: *const View, p: Pane) usize {
        return switch (p) {
            .artists => v.artists.items.len + 1,
            .albums => v.albums.items.len + 1,
            .tracks => v.visible.items.len,
        };
    }
    fn reveal(v: *View, l: Layout) void {
        if (v.selected < v.scroll[2]) v.scroll[2] = v.selected;
        const count = @max(1, l.rows(.tracks));
        if (v.selected >= v.scroll[2] + count) v.scroll[2] = v.selected + 1 - count;
    }
    fn pick(v: *View, p: Pane, i: usize) !void {
        switch (p) {
            .artists => {
                v.artist = if (i == 0) null else v.artists.items[i - 1];
                v.album = null;
                v.scroll[1] = 0;
                try v.names("album", &v.albums);
                try v.filter();
            },
            .albums => {
                v.album = if (i == 0) null else v.albums.items[i - 1];
                try v.filter();
            },
            .tracks => v.selected = i,
        }
    }
};

const App = struct {
    display: *Display,
    v: View,
    p: *Player,
    folder: []const u8,
    searching: bool = false,
    paste: enum { idle, selection, property } = .idle,
    accept_paste: bool = false,
    last_click: ?usize = null,
    last_time: u32 = 0,
    title_track: ?usize = null,
    message: []const u8 = "",
    dirty: bool = true,

    fn play(a: *App, row: usize) void {
        if (row >= a.v.visible.items.len) return;
        const id = a.v.visible.items[row];
        a.v.selected = row;
        a.v.reveal(Layout.make(a.display));
        a.message = "";
        a.p.play(id, a.v.tracks[id].path) catch |err| a.failed(err);
        a.dirty = true;
    }
    fn failed(a: *App, err: anyerror) void {
        a.p.stop();
        a.message = switch (err) {
            error.ConnectionFailed, error.SocketUnavailable => "Cannot reach the sound server",
            error.SoundRequestRejected => "Sound server refused playback",
            error.NoLayerIIIFrames => "No supported MP3 frames in this file",
            error.FileNotFound => "Track file is missing",
            else => @errorName(err),
        };
        a.dirty = true;
    }
    fn step(a: *App, forward: bool) void {
        if (a.v.visible.items.len == 0) return;
        const id = a.p.track orelse {
            a.play(a.v.selected);
            return;
        };
        const row = std.mem.findScalar(usize, a.v.visible.items, id) orelse {
            a.play(a.v.selected);
            return;
        };
        if (forward) {
            if (row + 1 < a.v.visible.items.len) a.play(row + 1) else a.p.stop();
        } else a.play(row -| 1);
        a.dirty = true;
    }
    fn toggle(a: *App) void {
        if (a.p.track == null) a.play(a.v.selected) else a.p.toggle() catch |err| a.failed(err);
        a.dirty = true;
    }
    fn seek(a: *App, target: usize) void {
        a.p.seek(target) catch |err| a.failed(err);
        a.dirty = true;
    }
    fn sidebar(a: *App, l: Layout, pane: Pane) !void {
        const d = a.display;
        const v = &a.v;
        const artist = pane == .artists;
        const top = if (artist) header_h else l.split;
        const list = if (artist) v.artists.items else v.albums.items;
        const choice = if (artist) v.artist else v.album;
        try d.label(18, top + 25, l.side - 30, theme.text, .bold, if (artist) "Artists" else "Albums");
        const first = v.scroll[@backingInt(pane)];
        for (0..l.rows(pane)) |r| {
            const i = first + r;
            if (i > list.len) break;
            const y = l.start(pane) + r * row_h;
            const s = if (i == 0) (if (artist) "All artists" else "All albums") else list[i - 1];
            const selected = if (choice) |val| i != 0 and std.mem.eql(u8, val, s) else i == 0;
            if (selected) {
                try d.rect(8, y, l.side - 16, row_h - 2, theme.filter_selection);
                try d.rect(8, y, 3, row_h - 2, theme.filter_marker);
            }
            try d.label(20, y + 19, l.side - 36, if (selected) theme.text else theme.muted, .normal, s);
        }
    }
    fn drawSearch(a: *App, box: Rect) !void {
        const d = a.display;
        const input = &a.v.query;
        try d.rect(box.x, box.y, box.w, box.h, if (a.searching) theme.accent else theme.slider_rail);
        try d.rect(box.x + 1, box.y + 1, box.w - 2, box.h - 2, theme.canvas);
        const x = box.x + 10;
        const width = box.w - 36;
        if (input.len == 0) {
            try d.label(x + 3, 31, width, theme.muted, .normal, "Search tracks (Ctrl+F)");
        } else {
            try d.label(box.x + box.w - 17, 31, 12, theme.muted, .normal, "x");
        }
        const view = X.inputViewport(input.text()[0..input.cursor], width);
        try d.label(x, 31, width, theme.text, .normal, input.text()[view.start..input.cursor]);
        try d.label(x + view.caret, 31, width - view.caret, theme.text, .normal, input.text()[input.cursor..]);
        if (a.searching) try d.rect(x + view.caret, 18, 1, 16, theme.accent);
    }
    fn queryChanged(a: *App) !void {
        a.last_click = null;
        try a.v.filter();
        a.dirty = true;
    }
    fn draw(a: *App) !void {
        const l = Layout.make(a.display);
        const d = a.display;
        const v = &a.v;
        if (a.title_track != a.p.track) {
            try d.setTitle(if (a.p.track) |id| v.tracks[id].title else null);
            a.title_track = a.p.track;
        }
        var buf: [160]u8 = undefined;
        try d.rect(0, 0, l.w, l.h, theme.canvas);
        try d.rect(0, 0, l.w, header_h, theme.chrome);
        for (0..logo.size) |row| {
            var col: usize = 0;
            while (col < logo.size) {
                const start = col;
                const color = logo.headerColor(col, row);
                col += 1;
                while (col < logo.size and logo.headerColor(col, row) == color) col += 1;
                if (color != theme.chrome) try d.rect(16 + start, (header_h - logo.size) / 2 + row, col - start, 1, color);
            }
        }
        try d.label(59, 32, 90, theme.text, .bold, "ampz");
        try a.drawSearch(l.searchBox());
        const total = v.visible.items.len;
        const count = try std.fmt.bufPrint(&buf, "{d} {s}", .{ total, if (total == 1) "track" else "tracks" });
        const count_w = count.len * 6;
        try d.label(l.w - 20 - count_w, 32, count_w, theme.muted, .normal, count);
        const folder_x = l.searchBox().x + l.searchBox().w + 16;
        const folder_w = (l.w - 32 - count_w) -| folder_x;
        if (folder_w >= 60) try d.label(folder_x, 32, folder_w, theme.muted, .normal, a.folder);
        try d.rect(0, header_h, l.side, l.bottom - header_h, theme.sidebar);
        try d.rect(l.side - 1, header_h, 1, l.bottom - header_h, theme.divider);
        try d.rect(0, l.split, l.side, 1, theme.divider);
        try a.sidebar(l, .artists);
        try a.sidebar(l, .albums);
        const tx = l.side + 18;
        const content = l.w - l.side - 36;
        try d.label(tx, header_h + 27, content, theme.text, .bold, if (v.album) |s| s else if (v.artist) |s| s else "All tracks");
        const artist_x = tx + content * 47 / 100;
        const album_x = tx + content * 73 / 100;
        try d.label(tx, header_h + 57, artist_x - tx, theme.muted, .normal, "Title");
        try d.label(artist_x, header_h + 57, album_x - artist_x, theme.muted, .normal, "Artist");
        try d.label(album_x, header_h + 57, l.w - album_x - 12, theme.muted, .normal, "Album");
        try d.rect(l.side, header_h + 67, l.w - l.side, 1, theme.divider);
        for (0..l.rows(.tracks)) |r| {
            const row = v.scroll[2] + r;
            if (row >= v.visible.items.len) break;
            const idx = v.visible.items[row];
            const t = v.tracks[idx];
            const y = l.start(.tracks) + r * row_h;
            if (row == v.selected) try d.rect(l.side, y, l.w - l.side, row_h, theme.track_selection);
            if (a.p.track == idx) try d.rect(l.side + 5, y + 8, 3, 15, theme.accent);
            try d.label(tx, y + 20, artist_x - tx - 12, theme.text, .normal, t.title);
            try d.label(artist_x, y + 20, album_x - artist_x - 12, theme.muted, .normal, t.artist);
            try d.label(album_x, y + 20, l.w - album_x - 12, theme.muted, .normal, t.album);
            try d.rect(l.side, y + row_h - 1, l.w - l.side, 1, theme.divider);
        }
        if (v.visible.items.len == 0) try d.label(tx, l.start(.tracks) + 35, content, theme.muted, .normal, if (v.tracks.len == 0) "No MP3 files in this folder." else "No tracks match the current filters.");
        const y = l.bottom;
        try d.rect(0, y, l.w, 84, theme.chrome);
        try d.glyph(.left, previous_button.x + 4, y + previous_button.y, 12, previous_button.h, theme.text, theme.chrome);
        try d.glyph(.capsule, previous_button.x, y + previous_button.y, 3, previous_button.h, theme.text, theme.chrome);
        try d.glyph(.capsule, play_button.x, y + play_button.y, play_button.w, play_button.h, theme.accent, theme.chrome);
        if (a.p.track != null and !a.p.paused) {
            try d.glyph(.capsule, play_button.x + 16, y + play_button.y + 14, 4, 16, theme.chrome, theme.accent);
            try d.glyph(.capsule, play_button.x + 24, y + play_button.y + 14, 4, 16, theme.chrome, theme.accent);
        } else try d.glyph(.right, play_button.x + 18, y + play_button.y + 13, 13, 18, theme.chrome, theme.accent);
        try d.glyph(.right, next_button.x, y + next_button.y, 12, next_button.h, theme.text, theme.chrome);
        try d.glyph(.capsule, next_button.x + 13, y + next_button.y, 3, next_button.h, theme.text, theme.chrome);
        const track = if (a.p.track) |id| &v.tracks[id] else if (v.visible.items.len != 0) &v.tracks[v.visible.items[v.selected]] else null;
        const end = l.w - 132;
        const name = if (a.message.len > 0) a.message else if (track) |t| t.title else "No track selected";
        try d.label(151, y + 24, end - 151, if (a.message.len > 0) theme.accent else theme.text, .bold, name);
        if (track) |t| try d.label(151, y + 41, end - 151, theme.muted, .normal, t.artist);
        const song = a.p.song;
        const elapsed = if (song) |s| a.p.position / s.format.rate else 0;
        const length = if (song) |s| s.length / s.format.rate else 0;
        const clock = try std.fmt.bufPrint(&buf, "{d}:{d:0>2} / {d}:{d:0>2}", .{ elapsed / 60, elapsed % 60, length / 60, length % 60 });
        try d.label(end - @min(end - 151, clock.len * 6), y + 70, clock.len * 6, theme.muted, .normal, clock);
        try d.rect(151, y + 50, end - 151, 3, theme.slider_rail);
        if (song) |s| try d.rect(151, y + 50, scalePosition(a.p.position, s.length, end - 151), 3, theme.accent);
        try d.label(l.w - 99, y + 34, 90, theme.muted, .normal, "Volume");
        const filled = 77 * a.p.volume / 100;
        const thumb = l.w - 99 + filled;
        try d.rect(l.w - 99, y + 49, filled -| 4, 3, theme.accent);
        try d.rect(thumb + 4, y + 49, (77 - filled) -| 4, 3, theme.slider_rail);
        try d.glyph(.capsule, thumb - 5, y + 45, 10, 10, theme.accent, theme.chrome);
        try d.present();
        a.dirty = false;
    }
    fn click(a: *App, button: u8, x: usize, y: usize, time: u32) !void {
        const l = Layout.make(a.display);
        a.dirty = true;
        if (button == 1) {
            const box = l.searchBox();
            a.searching = box.hit(x, y, 0);
            a.accept_paste = false;
            if (a.searching) {
                const input = &a.v.query;
                if (x >= box.x + box.w - 25 and input.len != 0) {
                    input.* = .{};
                    try a.queryChanged();
                } else {
                    const view = X.inputViewport(input.text()[0..input.cursor], box.w - 36);
                    input.cursor = view.start + X.inputHit(input.text()[view.start..], x -| (box.x + 10));
                }
                a.last_click = null;
                return;
            }
        }
        if (y >= l.bottom) {
            if (button != 1) return;
            const dy = y - l.bottom;
            const volume: Rect = .{ .x = l.w - 104, .y = 45, .w = 87, .h = 10 };
            if (previous_button.hit(x, dy, 6)) {
                a.step(false);
            } else if (play_button.hit(x, dy, 4)) {
                a.toggle();
            } else if (next_button.hit(x, dy, 6)) {
                a.step(true);
            } else if (volume.hit(x, dy, 4)) {
                a.p.volume = @min(100, (x -| (l.w - 99)) * 100 / 77);
            } else if (x >= 151 and x <= l.w - 132 and y >= l.bottom + 44 and y < l.bottom + 62) {
                if (a.p.song) |song| a.seek(scalePosition(x - 151, l.w - 132 - 151, song.length));
            }
            return;
        }
        if (y < header_h) return;
        const pane: Pane = if (x >= l.side) .tracks else if (y < l.split) .artists else .albums;
        const scroll = &a.v.scroll[@backingInt(pane)];
        const total = a.v.total(pane);
        if (button == 4 or button == 5) {
            scroll.* = if (button == 4) scroll.* -| 3 else @min(total -| l.rows(pane), scroll.* + 3);
            return;
        }
        if (button != 1 or y < l.start(pane)) return;
        const r = (y - l.start(pane)) / row_h;
        const i = scroll.* + r;
        if (i >= total or r >= l.rows(pane)) return;
        try a.v.pick(pane, i);
        if (pane == .tracks and a.last_click == i and time -% a.last_time < 450) {
            a.play(i);
            a.last_click = null;
        } else a.last_click = if (pane == .tracks) i else null;
        a.last_time = time;
    }
    fn key(a: *App, sym: u32, state: u16, time: u32) !bool {
        const ctrl = state & 4 != 0;
        if ((ctrl and (sym == 'f' or sym == 'F')) or (!a.searching and sym == '/')) {
            a.searching = true;
            a.v.query.cursor = a.v.query.len;
            a.dirty = true;
            return true;
        }
        if (a.searching) {
            const input = &a.v.query;
            a.dirty = true;
            if (ctrl) {
                switch (sym) {
                    'u', 'U' => {
                        input.* = .{};
                        try a.queryChanged();
                    },
                    'v', 'V' => if (a.paste == .idle) {
                        try a.display.requestPaste(time);
                        a.paste = .selection;
                        a.accept_paste = true;
                    },
                    else => {},
                }
                return true;
            }
            switch (sym) {
                0xff1b => {
                    input.* = .{};
                    try a.queryChanged();
                    a.searching = false;
                },
                0xff0d, 0xff8d => {
                    if (a.v.visible.items.len != 0) {
                        a.searching = false;
                        a.play(a.v.selected);
                    }
                },
                0xff09, 0xff54 => a.searching = false,
                0xff51, 0xff53 => input.move(sym == 0xff53),
                0xff50 => input.cursor = 0,
                0xff57 => input.cursor = input.len,
                0xff08, 0xffff => if (input.erase(sym == 0xffff)) try a.queryChanged(),
                else => {
                    const cp = @import("keysym.zig").codepoint(sym) orelse return true;
                    var bytes: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &bytes) catch return true;
                    if (input.insert(bytes[0..len])) try a.queryChanged();
                },
            }
            if (!a.searching) a.accept_paste = false;
            return true;
        }
        const count = a.v.visible.items.len;
        switch (sym) {
            'q', 'Q', 0xff1b => return false,
            ' ' => a.toggle(),
            0xff0d => a.play(a.v.selected),
            0xff52, 0xff54, 0xff55, 0xff56 => {
                const l = Layout.make(a.display);
                const n: usize = if (sym == 0xff55 or sym == 0xff56) l.rows(.tracks) else 1;
                a.v.selected = if (sym == 0xff52 or sym == 0xff55) a.v.selected -| n else @min(count -| 1, a.v.selected + n);
                a.v.reveal(l);
            },
            0xff51, 0xff53 => if (a.p.song) |s| {
                const delta = s.format.rate * 5;
                a.seek(if (sym == 0xff51) a.p.position -| delta else a.p.position + delta);
            },
            else => {},
        }
        a.dirty = true;
        return true;
    }
    fn event(a: *App) !bool {
        const packet = try a.display.nextEvent();
        const e = packet.header;
        switch (e[0] & 127) {
            0 => {
                std.log.err("X11 error {d} for request {d}", .{ e[1], e[10] });
                return error.X11RequestFailed;
            },
            1 => {
                if (e[0] != 1) return true;
                if (a.paste != .property) return error.UnexpectedDisplayReply;
                a.paste = .idle;
                const words = X.u32at(&e, 4);
                const len = X.u32at(&e, 16);
                if (a.accept_paste and e[1] == 8 and X.u32at(&e, 8) == a.display.utf8_atom and
                    X.u32at(&e, 12) == 0 and len <= words * 4 and a.v.query.insert(packet.data[0..len])) try a.queryChanged();
            },
            2 => {
                const state = X.u16at(&e, 28);
                return a.key(a.display.keySym(e[1], state), state, X.u32at(&e, 4));
            },
            31 => { // SelectionNotify
                if (a.paste == .selection and X.u32at(&e, 8) == a.display.window and
                    X.u32at(&e, 12) == a.display.clipboard and X.u32at(&e, 16) == a.display.utf8_atom)
                {
                    a.paste = .idle;
                    if (a.accept_paste and X.u32at(&e, 20) == 9) {
                        try a.display.requestPasteData(search.Input.capacity);
                        a.paste = .property;
                    }
                }
            },
            4 => try a.click(e[1], X.u16at(&e, 24), X.u16at(&e, 26), X.u32at(&e, 4)),
            12 => a.dirty = true,
            17 => return false,
            22 => {
                try a.display.resize(X.u16at(&e, 20), X.u16at(&e, 22));
                const l = Layout.make(a.display);
                inline for (.{ Pane.artists, Pane.albums, Pane.tracks }) |p| {
                    const i = @backingInt(p);
                    a.v.scroll[i] = @min(a.v.scroll[i], a.v.total(p) -| l.rows(p));
                }
                a.dirty = true;
            },
            34 => if (e[4] == 1) try a.display.refreshKeys(e[5], e[6]), // MappingKeyboard
            33 => if (X.u32at(&e, 8) == a.display.protocols and X.u32at(&e, 12) == a.display.delete_atom) return false,
            else => {},
        }
        return true;
    }
};
pub fn run(init: std.process.Init, display: *Display, tracks: []const Track, folder: []const u8, player: *Player) !void {
    var app: App = .{ .display = display, .folder = folder, .p = player, .v = .{ .alloc = init.gpa, .tracks = tracks } };
    defer app.v.artists.deinit(init.gpa);
    defer app.v.albums.deinit(init.gpa);
    defer app.v.visible.deinit(init.gpa);
    try app.v.names("artist", &app.v.artists);
    try app.v.names("album", &app.v.albums);
    try app.v.filter();
    while (true) {
        const prev_seconds = if (player.song) |s| player.position / s.format.rate else 0;
        player.pump() catch |err| app.failed(err);
        if (player.song) |s| {
            if (player.position / s.format.rate != prev_seconds) app.dirty = true;
        }
        if (player.stream) |stream| {
            if (stream.finished and !player.paused) {
                if (app.v.visible.items.len == 0) player.stop() else app.step(true);
                app.dirty = true;
            }
        }
        if (app.dirty) try app.draw();
        var fds = [_]sock.linux.pollfd{ .{ .fd = display.fd, .events = sock.linux.POLL.IN }, .{ .fd = if (player.stream) |s| s.fd else -1, .events = sock.linux.POLL.IN } };
        const queued = display.pending.items.len != 0;
        const rc = sock.linux.poll(&fds, 2, if (queued) 0 else -1);
        switch (sock.linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.DesktopPollFailed,
        }
        if (fds[1].revents != 0) {
            if (player.stream) |*s| {
                s.event() catch |err| app.failed(err);
            }
        }
        if ((queued or fds[0].revents != 0) and !try app.event()) return;
    }
}

test "artist selection narrows albums and resets the track selection" {
    const tracks = [_]Track{
        .{ .path = "1.mp3", .artist = "A", .album = "One", .title = "First" },
        .{ .path = "2.mp3", .artist = "A", .album = "Two", .title = "Second" },
        .{ .path = "3.mp3", .artist = "B", .album = "Two", .title = "Third" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var view: View = .{ .alloc = arena.allocator(), .tracks = &tracks };
    try view.names("artist", &view.artists);
    try view.pick(.artists, 2);
    try std.testing.expectEqual(@as(usize, 1), view.albums.items.len);
    try std.testing.expectEqualStrings("Two", view.albums.items[0]);
    try std.testing.expectEqualSlices(usize, &.{2}, view.visible.items);
    try view.pick(.artists, 0);
    try view.pick(.tracks, 2);
    try view.pick(.albums, 2);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, view.visible.items);
    try std.testing.expectEqual(@as(usize, 0), view.selected);
}

fn expectRedrawTitle(peer: sock.Fd, expected: ?[]const u8, title_atom: u32, utf8_atom: u32) !void {
    var found = false;
    while (true) {
        var request: [4096]u8 = undefined;
        try sock.read(peer, request[0..4]);
        const len = @as(usize, X.u16at(&request, 2)) * 4;
        try std.testing.expect(len >= 4 and len <= request.len);
        try sock.read(peer, request[4..len]);
        if (request[0] == 62) break; // CopyArea presents the completed redraw.
        if (request[0] == 18 and X.u32at(&request, 8) == title_atom) {
            try std.testing.expect(!found and expected != null);
            try std.testing.expectEqual(utf8_atom, X.u32at(&request, 12));
            try std.testing.expectEqual(8, request[16]);
            try std.testing.expectEqualStrings(expected.?, request[24..len][0..X.u32at(&request, 20)]);
            found = true;
        }
    }
    try std.testing.expectEqual(expected != null, found);
}

test "window title follows playback independently of browser selection" {
    const fds = try @import("test_socket.zig").pair();
    defer sock.close(fds[0]);
    defer sock.close(fds[1]);
    var display: Display = .{ .fd = fds[0], .base = 1, .window = 2, .gc = 3, .pixmap = 4, .depth = 24, .font_normal = 5, .font_bold = 6, .name_atom = 80, .utf8_atom = 81 };
    const tracks = [_]Track{
        .{ .title = "東京 🎶", .artist = "A", .album = "One", .path = "1.mp3" },
        .{ .title = "Evening", .artist = "A", .album = "One", .path = "2.mp3" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var player: Player = .{ .alloc = arena.allocator(), .io = std.testing.io, .dir = .cwd(), .settings = .{ .path = "" }, .track = 0 };
    var app: App = .{ .display = &display, .p = &player, .folder = "Music", .v = .{ .alloc = arena.allocator(), .tracks = &tracks } };
    try app.v.filter();

    try app.draw();
    try expectRedrawTitle(fds[1], tracks[0].title, display.name_atom, display.utf8_atom);
    try std.testing.expect(try app.key(0xff54, 0, 0)); // Browse the next row.
    try std.testing.expectEqual(1, app.v.selected);
    player.paused = true;
    try app.draw();
    try expectRedrawTitle(fds[1], null, display.name_atom, display.utf8_atom);
    player.track = 1;
    player.paused = false;
    try app.draw();
    try expectRedrawTitle(fds[1], tracks[1].title, display.name_atom, display.utf8_atom);
    player.stop();
    try app.draw();
    try expectRedrawTitle(fds[1], "ampz", display.name_atom, display.utf8_atom);
}

test "search editing narrows the current filters without triggering playback shortcuts" {
    const tracks = [_]Track{
        .{ .title = "Quiet night", .artist = "A", .album = "One", .path = "1.mp3" },
        .{ .title = "Quiet morning", .artist = "B", .album = "Two", .path = "2.mp3" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var display: Display = .{ .fd = -1, .base = 1, .window = 2, .gc = 3, .pixmap = 4, .depth = 24, .font_normal = 5, .font_bold = 6 };
    var player: Player = .{ .alloc = arena.allocator(), .io = std.testing.io, .dir = .cwd(), .settings = .{ .path = "" }, .track = 1 };
    var app: App = .{ .display = &display, .p = &player, .folder = "Music", .v = .{ .alloc = arena.allocator(), .tracks = &tracks, .artist = "A" } };
    try app.v.filter();
    try std.testing.expect(try app.key('f', 4, 0));
    for ("q n") |c| try std.testing.expect(try app.key(c, 0, 0));
    try std.testing.expectEqualStrings("q n", app.v.query.text());
    try std.testing.expectEqualSlices(usize, &.{0}, app.v.visible.items);
    try std.testing.expect(try app.key('z', 0, 0));
    try std.testing.expectEqual(0, app.v.visible.items.len);
    try std.testing.expect(try app.key(0xff1b, 0, 0));
    try std.testing.expect(!app.searching);
    try std.testing.expectEqualSlices(usize, &.{0}, app.v.visible.items);
    try std.testing.expectEqual(@as(?usize, 1), player.track);
}

test "guest artist filter and search find a duet by either performer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tracks = [_]Track{
        .{ .artist = "Lead, Guest", .artists = &.{ "Lead", "Guest" }, .album = "Duets", .title = "Nightfall", .path = "1.mp3" },
        .{ .artist = "Lead", .album = "Solo", .title = "Morning", .path = "2.mp3" },
    };
    var view: View = .{ .alloc = arena.allocator(), .tracks = &tracks };
    try view.names("artist", &view.artists);
    try std.testing.expectEqual(2, view.artists.items.len);
    try std.testing.expectEqualStrings("Guest", view.artists.items[0]);
    try std.testing.expect(view.query.insert("gue night"));
    try view.pick(.artists, 1);
    try std.testing.expectEqualStrings("Duets", view.albums.items[0]);
    try std.testing.expectEqualSlices(usize, &.{0}, view.visible.items);
}
