// EXPECT: 4:11 warning unused-decl Declaration 'bar' is never used
// EXPECT: 6:8 warning unused-decl Declaration 'baz' is never used
const foo = struct {
    const bar = struct {};

    fn baz() void {}

    pub const used_pub = 1;
};

pub fn main() void {
    _ = foo;
}
