// EXPECT: line=6 rule=identifier-style
// This test validates that ZIR-based type information correctly identifies
// constants that are incorrectly named with PascalCase.

// This is a constant value, not a type - ZIR knows this should be snake_case
const MaxSize: usize = 1024;
