// EXPECT: none
const FooType = struct {};
const BarType = struct {};

const Chosen = switch (0) {
    0 => FooType,
    1 => BarType,
    else => @compileError("unsupported"),
};
