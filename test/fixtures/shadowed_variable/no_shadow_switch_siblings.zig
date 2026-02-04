// Test: switch cases are sibling scopes
// EXPECT: none
const Tag = enum { a, b };

fn foo(tag: Tag) void {
    switch (tag) {
        .a => {
            const value = 1;
            _ = value;
        },
        .b => {
            const value = 2;
            _ = value;
        },
    }
}
