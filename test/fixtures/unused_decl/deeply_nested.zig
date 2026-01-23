// EXPECT: 5:15 warning unused-decl Declaration 'unused_inner' is never used
// EXPECT: 9:11 warning unused-decl Declaration 'unused_outer' is never used
const outer = struct {
    const inner = struct {
        const unused_inner = 1;
        const used_inner = 2;
    };

    const unused_outer = inner.used_inner;

    pub fn get() i32 {
        return inner.used_inner;
    }
};

pub fn main() void {
    _ = outer.get();
}
