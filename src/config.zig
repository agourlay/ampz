const std = @import("std");
const Dir = std.Io.Dir;
const path = std.fs.path;

pub fn location(alloc: std.mem.Allocator, xdg: ?[]const u8, home: ?[]const u8) !?[]const u8 {
    if (xdg) |base| {
        if (path.isAbsolute(base)) return try path.join(alloc, &.{ base, "ampz", "config.json" });
    }
    if (home) |base| {
        if (path.isAbsolute(base)) return try path.join(alloc, &.{ base, ".config", "ampz", "config.json" });
    }
    return null;
}

// The process arena owns the document and strings for the duration of startup.
fn read(alloc: std.mem.Allocator, io: std.Io, file: []const u8) !std.json.Value {
    const bytes = Dir.cwd().readFileAlloc(io, file, alloc, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .object = .empty },
        else => return err,
    };
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{ .parse_numbers = false });
    if (doc != .object) return error.ExpectedConfigObject;
    return doc;
}

pub fn folder(alloc: std.mem.Allocator, io: std.Io, file: []const u8) !?[]const u8 {
    const doc = try read(alloc, io, file);
    const field = doc.object.get("music_folder") orelse return null;
    if (field == .null) return null;
    if (field != .string or field.string.len == 0 or std.mem.findScalar(u8, field.string, 0) != null) return error.InvalidMusicFolder;
    if (path.isAbsolute(field.string)) return field.string;
    return try path.join(alloc, &.{ path.dirname(file).?, field.string });
}

pub fn save(alloc: std.mem.Allocator, io: std.Io, file: []const u8, music: []const u8) !void {
    const dir = try Dir.cwd().openDir(io, music, .{ .iterate = true });
    defer dir.close(io);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(io, &buffer);
    const absolute = buffer[0..n];
    if (!std.unicode.utf8ValidateSlice(absolute)) return error.InvalidUtf8;
    var doc = try read(alloc, io, file);
    try doc.object.put(alloc, "music_folder", .{ .string = absolute });
    const parent = try Dir.cwd().createDirPathOpen(io, path.dirname(file).?, .{ .permissions = .fromMode(0o700) });
    defer parent.close(io);
    var output = try parent.createFileAtomic(io, path.basename(file), .{ .replace = true, .permissions = .fromMode(0o600) });
    defer output.deinit(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = output.file.writer(io, &write_buffer);
    try std.json.Stringify.value(doc, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.flush();
    try output.replace(io);
}

test "XDG config location and saved folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("/prefs/ampz/config.json", (try location(alloc, "/prefs", null)).?);
    try std.testing.expectEqualStrings("/home/me/.config/ampz/config.json", (try location(alloc, "relative", "/home/me")).?);
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    const file = try path.join(alloc, &.{ root, "ampz", "config.json" });
    try std.testing.expect(try folder(alloc, io, file) == null);
    try save(alloc, io, file, root);
    try std.testing.expectEqualStrings(root, (try folder(alloc, io, file)).?);
    try tmp.dir.writeFile(io, .{ .sub_path = "ampz/config.json", .data = "{\"music_folder\":\"collection\",\"future_option\":true}" });
    const relative = try path.join(alloc, &.{ root, "ampz", "collection" });
    try std.testing.expectEqualStrings(relative, (try folder(alloc, io, file)).?);
    try save(alloc, io, file, root);
    const doc = try read(alloc, io, file);
    try std.testing.expect(doc.object.get("future_option").?.bool);
}
