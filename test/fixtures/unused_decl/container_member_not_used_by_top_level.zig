// EXPECT: line=3 rule=unused-decl message=inner
const Holder = struct {
    const inner = 1;
};

const inner = 2;

pub fn main() void {
    _ = Holder;
    _ = inner;
}
