// Test: container scopes are isolated from each other
// EXPECT: none
const Outer = struct {
    const x = 1;

    const Inner = struct {
        const x = 2;
    };
};

const Another = struct {
    const x = 3;
};
