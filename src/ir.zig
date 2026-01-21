const std = @import("std");
const diagnostic = @import("diagnostic.zig");
pub const SourceRange = diagnostic.SourceRange;
pub const Location = diagnostic.Location;

/// IR node tags representing different kinds of statements and expressions.
/// This is a minimal IR designed for control-flow analysis.
pub const IrTag = enum {
    /// Function entry point
    fn_entry,
    /// Function exit point (normal return path)
    fn_exit,
    /// Return statement
    ret,
    /// Variable declaration (const/var)
    var_decl,
    /// Assignment expression
    assign,
    /// Function call expression
    call,
    /// Block of statements
    block,
    /// Generic expression that doesn't fit other categories
    expr,
    /// No-op placeholder for control flow merge points
    nop,
    /// Branch condition evaluation (if/else)
    branch,
    /// While loop header (condition evaluation)
    loop_header,
    /// Loop body entry point
    loop_body,
    /// Defer statement body
    defer_stmt,
    /// Errdefer statement body
    errdefer_stmt,
    /// Try expression - propagates errors to caller
    try_expr,
    /// Catch expression - handles errors locally
    catch_expr,
};

/// A single IR node representing a statement or expression.
/// IR nodes are lightweight references that map back to AST nodes
/// and source locations.
pub const IrNode = struct {
    /// The kind of IR node
    tag: IrTag,
    /// Index of the corresponding AST node (if any)
    ast_node: ?u32,
    /// Source range for diagnostic reporting
    source_range: ?SourceRange,
    /// Additional operand node for tags that need it (e.g., LHS of assign, RHS value)
    operand_node: ?u32,
    /// Second operand for tags that need two (e.g., RHS of assign)
    operand2_node: ?u32,

    pub fn init(tag: IrTag) IrNode {
        return .{
            .tag = tag,
            .ast_node = null,
            .source_range = null,
            .operand_node = null,
            .operand2_node = null,
        };
    }

    pub fn initWithAst(tag: IrTag, ast_node: u32) IrNode {
        return .{
            .tag = tag,
            .ast_node = ast_node,
            .source_range = null,
            .operand_node = null,
            .operand2_node = null,
        };
    }

    pub fn initWithRange(tag: IrTag, range: SourceRange) IrNode {
        return .{
            .tag = tag,
            .ast_node = null,
            .source_range = range,
            .operand_node = null,
            .operand2_node = null,
        };
    }

    pub fn initFull(tag: IrTag, ast_node: u32, range: SourceRange) IrNode {
        return .{
            .tag = tag,
            .ast_node = ast_node,
            .source_range = range,
            .operand_node = null,
            .operand2_node = null,
        };
    }

    pub fn initAssign(ast_node: u32, lhs_node: u32, rhs_node: u32, range: SourceRange) IrNode {
        return .{
            .tag = .assign,
            .ast_node = ast_node,
            .source_range = range,
            .operand_node = lhs_node,
            .operand2_node = rhs_node,
        };
    }
};

test "IrNode initialization" {
    const testing = std.testing;

    const node1 = IrNode.init(.fn_entry);
    try testing.expectEqual(IrTag.fn_entry, node1.tag);
    try testing.expect(node1.ast_node == null);
    try testing.expect(node1.source_range == null);

    const node2 = IrNode.initWithAst(.var_decl, 42);
    try testing.expectEqual(IrTag.var_decl, node2.tag);
    try testing.expectEqual(@as(u32, 42), node2.ast_node.?);
    try testing.expect(node2.source_range == null);

    const range = SourceRange.init(Location.init(1, 5), Location.init(1, 10));
    const node3 = IrNode.initFull(.ret, 10, range);
    try testing.expectEqual(IrTag.ret, node3.tag);
    try testing.expectEqual(@as(u32, 10), node3.ast_node.?);
    try testing.expectEqual(@as(usize, 1), node3.source_range.?.start.line);
    try testing.expectEqual(@as(usize, 5), node3.source_range.?.start.column);
}
