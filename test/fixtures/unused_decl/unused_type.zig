// EXPECT: line=5 rule=unused-decl message=Type
// EXPECT: line=5 rule=unused-decl message=UnusedStruct
// This test validates that ZIR-based type info provides better
// diagnostic messages for unused type declarations.
const UnusedStruct = struct {
    value: i32,
};

pub fn main() void {}
