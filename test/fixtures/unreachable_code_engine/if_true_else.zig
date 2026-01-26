// EXPECT: line=5 rule=unreachable-code-engine
fn foo() i32 {
    if (true) {
        return 1;
    } else {
        return 0;
    }
}
