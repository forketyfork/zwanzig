// Tests that lazy initialization pattern is recognized as safe
// After `if (x == null) { x = init(); }`, x is guaranteed non-null
// EXPECT: none
const Self = struct {
    cached: ?u32 = null,

    pub fn get(self: *Self) *u32 {
        if (self.cached == null) {
            self.cached = 42;
        }
        return &self.cached.?;
    }
};

pub fn main() void {
    var s = Self{};
    _ = s.get();
}
