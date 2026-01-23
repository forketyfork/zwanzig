// EXPECT: none
const foo = struct {
    pub const bar = 1;
    pub const baz = 2;

    pub fn process() void {}
};

pub fn main() void {
    _ = foo;
}
