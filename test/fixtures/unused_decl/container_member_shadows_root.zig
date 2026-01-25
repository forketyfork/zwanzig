// EXPECT: line=6 rule=unused-decl message=Declaration
const Foo = struct {
    value: i32,
};
const Container = struct {
    const Foo = 1;
};
pub fn main() void {
    _ = Foo;
    _ = Container;
}
