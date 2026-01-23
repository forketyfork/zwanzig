// EXPECT: line=2 rule=unused-decl message=config
const config = 1;

pub fn run(config: i32) void {
    _ = config;
}
