pub const Event = union(EventTag) {
    click: Click,
};

pub const EventTag = enum {
    click,
};

pub const Click = struct {};

pub const UnusedUnionHelper = struct {};
