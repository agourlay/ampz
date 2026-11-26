const std = @import("std");
const config = @import("config.zig");
const library = @import("library.zig");
const pulse = @import("pulse.zig");
const x11 = @import("x11.zig");
const Player = @import("player.zig").Player;
const ui = @import("ui.zig");

const usage =
    \\Usage: ampz [MUSIC_FOLDER]
    \\       ampz --set-music-dir MUSIC_FOLDER
    \\
    \\Open a folder and its subfolders as an MP3 library.
    \\Save a preferred folder with --set-music-dir. A folder argument overrides
    \\AMPZ_MUSIC_DIR and the saved preference for the current launch.
    \\
;
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        var out = std.Io.File.stdout().writer(init.io, &.{});
        try out.interface.writeAll(usage);
        return;
    }
    const setting = args.len > 1 and std.mem.eql(u8, args[1], "--set-music-dir");
    if ((setting and args.len != 3) or (!setting and args.len > 2)) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    const file = try config.location(alloc, init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME"));
    if (setting) {
        const dest = file orelse {
            std.log.err("set XDG_CONFIG_HOME or HOME to save a preferred folder", .{});
            std.process.exit(1);
        };
        config.save(alloc, init.io, dest, args[2]) catch |err| {
            std.log.err("cannot save folder '{s}' to {s} ({s})", .{ args[2], dest, @errorName(err) });
            std.process.exit(1);
        };
        return;
    }
    const override = if (args.len == 2) args[1] else init.environ_map.get("AMPZ_MUSIC_DIR");
    const selected = override orelse if (file) |source| config.folder(alloc, init.io, source) catch |err| {
        std.log.err("cannot read music folder from {s} ({s})", .{ source, @errorName(err) });
        std.process.exit(1);
    } else null;
    const folder = selected orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    };
    var dir = std.Io.Dir.cwd().openDir(init.io, folder, .{ .iterate = true }) catch |err| {
        std.log.err("cannot open music folder '{s}' ({s})", .{ folder, @errorName(err) });
        std.process.exit(1);
    };
    defer dir.close(init.io);
    var display = x11.Display.open(init) catch |err| {
        std.log.err("cannot open the local X11 display ({s}). Launch ampz in an X11 or XWayland desktop session.", .{@errorName(err)});
        std.process.exit(1);
    };
    defer display.close();
    const tracks = try library.scan(init.arena.allocator(), init.io, dir);
    var player: Player = .{ .alloc = init.gpa, .io = init.io, .dir = dir, .settings = try pulse.Settings.init(init) };
    defer player.stop();
    try ui.run(init, &display, tracks, folder, &player);
}
test {
    _ = @import("config.zig");
    _ = @import("mp3.zig");
    _ = @import("library.zig");
    _ = @import("player.zig");
    _ = @import("pulse.zig");
    _ = @import("ui.zig");
    _ = @import("x11.zig");
}
