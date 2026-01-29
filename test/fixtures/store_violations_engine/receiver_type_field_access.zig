const std = @import("std");
// zwanzig-disable: unused-decl

const MyPool = struct {
    fn acquire(_: *MyPool) i32 {
        return 1;
    }
};

const Context = struct {
    pool: MyPool,
};

fn leakFromFieldAccess() void {
    var ctx = Context{ .pool = MyPool{} };
    const handle = ctx.pool.acquire();
    _ = handle;
}

// CONFIG: {"resource_models":[{"kind":"open","method_name":"acquire","receiver_type":"MyPool"}]}
// EXPECT: line=16 rule=store-violations-engine severity=error message=resource leak
