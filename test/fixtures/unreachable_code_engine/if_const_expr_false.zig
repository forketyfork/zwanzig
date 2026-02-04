// EXPECT: line=3 rule=unreachable-code-engine
fn foo() i32 {
    if (1 == 2) {
        return 1;
    }
    return 0;
}
