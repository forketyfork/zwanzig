// EXPECT: line=2 rule=unused-decl message=value
const value = 1;

pub fn run(opt: ?i32) void {
    if (opt) |value| {
        _ = value;
    }
}
