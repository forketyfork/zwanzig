// EXPECT: none
const Posix = struct {
    pub const fd_t = u32;
};

const Fd = Posix.fd_t;

const ObjcMsgSend = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;

const Foo = struct {
    pub fn bar() u8 {
        return 0;
    }
};

const ReadonlyHandler = @typeInfo(@TypeOf(Foo.bar)).@"fn".return_type.?;

const Pty = switch (0) {
    0 => Posix.fd_t,
    else => @compileError("unsupported"),
};
