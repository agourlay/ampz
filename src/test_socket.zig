const sock = @import("socket.zig");

// Nonblocking ends turn a missing protocol message into a test failure.
pub fn pair() ![2]sock.Fd {
    var fds: [2]sock.Fd = undefined;
    const rc = sock.linux.socketpair(sock.linux.AF.UNIX, sock.linux.SOCK.STREAM | sock.linux.SOCK.NONBLOCK | sock.linux.SOCK.CLOEXEC, 0, &fds);
    if (sock.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    return fds;
}
