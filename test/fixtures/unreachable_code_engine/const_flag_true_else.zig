// EXPECT: line=6 rule=unreachable-code-engine
fn foo() i32 {
    const enabled = true;
    if (enabled) {
        return 1;
    } else {
        return 0;
    }
}
