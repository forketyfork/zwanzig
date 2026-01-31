// EXPECT: line=4 rule=unreachable-code-engine
fn foo() i32 {
    const debug = false;
    if (debug) {
        return 1;
    }
    return 0;
}
