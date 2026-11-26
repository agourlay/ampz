//! The two desktop services use local Unix stream sockets.
const std = @import("std");
pub const linux = std.os.linux;
pub const Fd = linux.fd_t;

pub fn connect(path: []const u8) !Fd {
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len == 0 or path.len >= addr.path.len) return error.InvalidSocketPath;
    @memcpy(addr.path[0..path.len], path);
    const raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(raw) != .SUCCESS) return error.SocketUnavailable;
    const fd: Fd = @intCast(raw);
    errdefer close(fd);
    if (linux.errno(linux.connect(fd, &addr, @intCast(2 + path.len + 1))) != .SUCCESS) return error.ConnectionFailed;
    return fd;
}
pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}
pub fn read(fd: Fd, buffer: []u8) !void {
    var rest = buffer;
    while (rest.len != 0) {
        const n = linux.read(fd, rest.ptr, rest.len);
        switch (linux.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (n == 0) return error.Disconnected;
        rest = rest[n..];
    }
}
pub fn write(fd: Fd, buffer: []const u8) !void {
    var rest = buffer;
    while (rest.len != 0) {
        const slice = [_]std.posix.iovec_const{.{ .base = rest.ptr, .len = rest.len }};
        const n = linux.sendmsg(fd, &.{
            .name = null,
            .namelen = 0,
            .iov = &slice,
            .iovlen = slice.len,
            .control = null,
            .controllen = 0,
            .flags = 0,
        }, linux.MSG.NOSIGNAL);
        switch (linux.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Disconnected,
        }
        if (n == 0) return error.Disconnected;
        rest = rest[n..];
    }
}
