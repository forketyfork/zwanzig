// Test: function local shadows file-level const
// EXPECT: line=6 col=11 rule=shadowed-variable message=shadows
const config = 42;

fn foo() void {
    const config = 100;
    _ = config;
}
