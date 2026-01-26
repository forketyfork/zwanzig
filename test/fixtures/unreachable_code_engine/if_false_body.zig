// EXPECT: line=3 rule=unreachable-code-engine
fn foo() i32 {
    if (false) {
        return 1;
    }
    return 0;
}
