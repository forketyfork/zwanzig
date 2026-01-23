// EXPECT: line=2 rule=unused-decl message=index
const index = 1;

pub fn main() void {
    const items = [_]i32{1};
    for (items, 0..) |item, index| {
        _ = item;
        _ = index;
    }
}
