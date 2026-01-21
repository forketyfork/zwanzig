#!/bin/bash
# Validation script for zwanzig static analyzer

echo "Zwanzig Static Analyzer - Structure Validation"
echo "================================================"
echo ""

ERRORS=0

# Check for required files
echo "Checking project structure..."

check_file() {
    if [ -f "$1" ]; then
        echo "✓ $1"
    else
        echo "✗ $1 (missing)"
        ERRORS=$((ERRORS + 1))
    fi
}

check_file "build.zig"
check_file "src/main.zig"
check_file "src/analyzer.zig"
check_file "src/rule.zig"
check_file "src/rules/empty_catch.zig"
check_file "examples/bad_example.zig"
check_file "examples/good_example.zig"
check_file "README.md"
check_file ".gitignore"

echo ""
echo "Checking code structure..."

# Check if main.zig imports required modules
if grep -q "const Analyzer = @import" src/main.zig && \
   grep -q "const Rule = @import" src/main.zig && \
   grep -q "const EmptyCatchRule = @import" src/main.zig; then
    echo "✓ main.zig has required imports"
else
    echo "✗ main.zig missing required imports"
    ERRORS=$((ERRORS + 1))
fi

# Check if analyzer has rule registration
if grep -q "registerRule" src/analyzer.zig; then
    echo "✓ analyzer.zig has rule registration"
else
    echo "✗ analyzer.zig missing rule registration"
    ERRORS=$((ERRORS + 1))
fi

# Check if empty_catch rule implements check function
if grep -q 'fn check(source: \[\]const u8' src/rules/empty_catch.zig; then
    echo "✓ empty_catch.zig implements check function"
else
    echo "✗ empty_catch.zig missing check function"
    ERRORS=$((ERRORS + 1))
fi

# Check if empty_catch has tests
if grep -q "test \"empty catch block detection\"" src/rules/empty_catch.zig; then
    echo "✓ empty_catch.zig has unit tests"
else
    echo "✗ empty_catch.zig missing unit tests"
    ERRORS=$((ERRORS + 1))
fi

# Check examples
echo ""
echo "Validating examples..."

BAD_CATCHES=$(grep -c "catch {}" examples/bad_example.zig)
BAD_CATCHES_WITH_ERR=$(grep -c "catch |err| {}" examples/bad_example.zig)
TOTAL_BAD=$((BAD_CATCHES + BAD_CATCHES_WITH_ERR))

if [ $TOTAL_BAD -ge 2 ]; then
    echo "✓ bad_example.zig has $TOTAL_BAD empty catch blocks"
else
    echo "✗ bad_example.zig should have at least 2 empty catch blocks, found $TOTAL_BAD"
    ERRORS=$((ERRORS + 1))
fi

GOOD_EMPTY=$(grep -c "catch {}" examples/good_example.zig 2>/dev/null)
if [ "$GOOD_EMPTY" = "0" ]; then
    echo "✓ good_example.zig has no empty catch blocks"
else
    echo "✗ good_example.zig should have no empty catch blocks, found $GOOD_EMPTY"
    ERRORS=$((ERRORS + 1))
fi

# Check if good example has proper error handling
if grep -q "catch |err|" examples/good_example.zig && \
   grep -q "return err" examples/good_example.zig; then
    echo "✓ good_example.zig demonstrates proper error handling"
else
    echo "✗ good_example.zig missing proper error handling examples"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "Checking architecture..."

# Check for extensibility
if grep -q "pub const Rule = struct" src/rule.zig; then
    echo "✓ Rule interface defined"
else
    echo "✗ Rule interface not found"
    ERRORS=$((ERRORS + 1))
fi

if grep -q "pub const Violation = struct" src/rule.zig; then
    echo "✓ Violation struct defined"
else
    echo "✗ Violation struct not found"
    ERRORS=$((ERRORS + 1))
fi

# Summary
echo ""
echo "================================================"
if [ $ERRORS -eq 0 ]; then
    echo "✓ All validation checks passed!"
    echo ""
    echo "The analyzer appears to be correctly structured."
    echo "Run 'zig build' to compile and 'zig build test' to run tests."
    exit 0
else
    echo "✗ Found $ERRORS error(s)"
    exit 1
fi
