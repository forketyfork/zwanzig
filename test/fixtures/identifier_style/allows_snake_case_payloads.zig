// EXPECT: none
const Value = union(enum) {
    ok: i32,
    err: u8,
};

fn bar() !void {
    return;
}

fn foo(opt: ?i32) !void {
    if (opt) |value| {
        _ = value;
    }

    const items = [_]i32{ 1, 2 };
    for (items) |item| {
        _ = item;
    }
    for (items, 0..) |item, index| {
        _ = item;
        _ = index;
    }

    while (opt) |value2| {
        _ = value2;
        break;
    }

    _ = bar() catch |err| {
        _ = err;
    };

    errdefer |err| {
        _ = err;
    };

    switch (Value{ .ok = 1 }) {
        .ok => |value_ok| {
            _ = value_ok;
        },
        .err => |err_val| {
            _ = err_val;
        },
    }
}
