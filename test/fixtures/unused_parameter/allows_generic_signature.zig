// EXPECT: none
// Generic parameters used only in type annotations should not be flagged.

// Parameter used in other parameter's type
fn make(comptime T: type, value: T) void {
    _ = value;
}

// Parameter used in return type
fn getDefault(comptime T: type) T {
    return undefined;
}

// Parameter used in both parameter type and return type
fn identity(comptime T: type, value: T) T {
    return value;
}

// Parameter used in pointer type
fn slice(comptime T: type, ptr: [*]T, len: usize) []T {
    return ptr[0..len];
}

// Parameter used in optional type
fn maybeValue(comptime T: type, opt: ?T) ?T {
    return opt;
}
