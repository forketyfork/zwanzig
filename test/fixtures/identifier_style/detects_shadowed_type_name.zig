// EXPECT: line=4 rule=identifier-style
const Foo = struct { value: i32 };
pub fn main() void {
    const Foo = 1;
    _ = Foo;
}
