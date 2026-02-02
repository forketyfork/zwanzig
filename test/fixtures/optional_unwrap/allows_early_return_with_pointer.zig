// Tests that early return guards unwrap even when returning a pointer to the value
// After `if (x == null) { return null; }`, x is known to be non-null
// EXPECT: none
const Self = struct {
    cached: ?u32,

    pub fn get(self: *Self) ?*u32 {
        if (self.cached == null) {
            return null;
        }
        return &self.cached.?;
    }
};
