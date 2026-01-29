// zwanzig-disable: unused-decl

const std = struct {
    const fs = struct {
        fn open() i32 {
            return 1;
        }
    };
};

fn shouldNotBeOpen() void {
    const handle = std.fs.open();
    _ = handle;
}

// EXPECT: none
