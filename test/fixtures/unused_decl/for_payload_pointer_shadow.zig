// EXPECT: line=2 rule=unused-decl message=value
const value = 1;

pub fn main() void {
    const items = [_]i32{1};
    for (items) |*value| {
        _ = value;
    }
}
