// EXPECT: line=9 rule=identifier-style
const Value = union(enum) {
    ok: i32,
    err: u8,
};

fn foo(value: Value) void {
    switch (value) {
        .ok => |BadValue| {
            _ = BadValue;
        },
        else => {},
    }
}
