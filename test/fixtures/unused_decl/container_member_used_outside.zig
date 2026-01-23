// EXPECT: none
const Holder = struct {
    const inner = 1;
};

pub fn main() void {
    _ = Holder.inner;
}
