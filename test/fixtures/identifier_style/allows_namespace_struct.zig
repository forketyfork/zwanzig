// EXPECT: none
// Namespace modules can use lowercase (like std.mem, std.fs)
pub const utils = struct {
    pub fn helper() void {}
};
