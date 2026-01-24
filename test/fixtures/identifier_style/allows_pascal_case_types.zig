// EXPECT: none
const MyStruct = struct {
    value: i32,
};

const MyEnum = enum {
    one,
    two,
};

const MyUnion = union {
    int: i32,
    float: f32,
};

const MyError = error{
    InvalidInput,
    OutOfMemory,
};
