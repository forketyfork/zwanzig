// EXPECT: line=5 rule=empty-defer
fn foo(x: u8) void {
    switch (x) {
        0 => {
            defer {}
        },
        else => {},
    }
}
