const std = @import("std");
const posix = std.posix;
// zwanzig-disable: unused-decl

const Pty = struct {
    master: posix.fd_t,
    slave: posix.fd_t,

    fn open() !Pty {
        const master = try posix.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
        errdefer posix.close(master);
        const slave = try posix.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
        return .{ .master = master, .slave = slave };
    }
};

fn spawn() !void {
    var pty = try Pty.open();
    defer {
        _ = posix.close(pty.master);
        _ = posix.close(pty.slave);
    }
    _ = pty.master;
}

// EXPECT: none
