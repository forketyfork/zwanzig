// Tests that assignment with orelse return guards the unwrap
// Pattern: x = foo() orelse return error; x.?
// EXPECT: none
const Self = struct {
    tex: ?u32,
};

fn createTexture() ?u32 {
    return 42;
}

pub fn getSize(self: *Self) !u32 {
    self.tex = createTexture() orelse return error.Failed;
    return self.tex.?;
}
