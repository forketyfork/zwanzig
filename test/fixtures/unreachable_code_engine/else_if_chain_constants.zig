// EXPECT: line=4 rule=unreachable-code-engine
// EXPECT: line=8 rule=unreachable-code-engine
fn foo() i32 {
    if (false) {
        return 1;
    } else if (true) {
        return 2;
    } else {
        return 3;
    }
}
