// EXPECT: line=2 rule=unused-decl message=foo
const foo = 1;

const Bar = struct {
    foo: i32,
};

pub fn run() void {
    _ = Bar{ .foo = 1 };
}
