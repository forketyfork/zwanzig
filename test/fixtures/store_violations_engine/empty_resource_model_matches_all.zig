const std = @import("std");
// zwanzig-disable: unused-decl

const Widget = struct {
    fn ping(_: *Widget) i32 {
        return 1;
    }
};

fn shouldNotBeResource() void {
    var widget = Widget{};
    const res = widget.ping();
    _ = res;
}

// CONFIG: {"resource_models":[{"kind":"open"}]}
// EXPECT: none
