// EXPECT: none
const config: i32 = 100;

pub fn process() void {
    if (true) {
        _ = config;
    }
}
