fn count(items: *[2]u32) usize {
    _ = items;
    return 0;
}

fn good() usize {
    var buf: [2]u32 = undefined;
    return count(&buf);
}
