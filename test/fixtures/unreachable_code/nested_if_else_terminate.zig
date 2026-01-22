// EXPECT: line=17 rule=unreachable-code
// EXPECT: line=18 rule=unreachable-code
fn deeplyNested(a: bool, b: bool, c: bool) void {
    if (a) {
        if (b) {
            if (c) {
                return;
            } else {
                return;
            }
        } else {
            return;
        }
    } else {
        return;
    }
    const z: i32 = 1;
    _ = z;
}
