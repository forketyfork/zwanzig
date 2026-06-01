// CONFIG: {"resource_models":[{"kind":"open","method_name":"makeHandle"}]}
// EXPECT: rule=store-violations-engine severity=error message=resource
// zwanzig-disable: unused-decl

fn makeHandle() i32 {
    return 1;
}

fn leakFromIdentifierModel() void {
    const handle = makeHandle();
    _ = handle;
}
