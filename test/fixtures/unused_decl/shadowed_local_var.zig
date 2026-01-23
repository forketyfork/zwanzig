// EXPECT: line=2 rule=unused-decl message=shadowed
const shadowed = 1;

pub fn run() void {
    const shadowed = 2;
    _ = shadowed;
}
