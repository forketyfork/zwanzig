// EXPECT: none
const foo = struct {
    const bar = 42;

    fn baz() i32 {
        return bar;
    }

    pub fn process() i32 {
        return baz();
    }
};

pub fn main() void {
    _ = foo.process();
}
