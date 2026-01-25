const std = @import("std");
const Source = @import("source.zig").Source;
const zir_bridge_mod = @import("zir_bridge.zig");

pub const TypeInfo = zir_bridge_mod.TypeInfo;
pub const DeclInfo = zir_bridge_mod.DeclInfo;
pub const ZirBridge = zir_bridge_mod.ZirBridge;

/// TypeContext provides a unified interface for type information queries.
/// It wraps ZirBridge and provides convenient methods for checkers and rules
/// to query type information during analysis.
///
/// The context supports:
/// - Declaration type lookups by name
/// - AST node to type mappings
/// - Type kind queries (is this an error union? optional? pointer?)
/// - Future: cross-file type resolution
pub const TypeContext = struct {
    allocator: std.mem.Allocator,
    source: *Source,

    /// Cache for frequently queried types by AST node index.
    /// This avoids repeated ZIR lookups for the same nodes.
    node_type_cache: std.AutoHashMap(u32, TypeInfo),

    pub fn init(allocator: std.mem.Allocator, source: *Source) TypeContext {
        return .{
            .allocator = allocator,
            .source = source,
            .node_type_cache = std.AutoHashMap(u32, TypeInfo).init(allocator),
        };
    }

    pub fn deinit(self: *TypeContext) void {
        self.node_type_cache.deinit();
    }

    // =========================================================================
    // Core Type Query API
    // =========================================================================

    /// Check if type information is available.
    pub fn isAvailable(self: *TypeContext) bool {
        return self.source.hasTypeInfo();
    }

    /// Get the ZirBridge if available.
    pub fn getZirBridge(self: *TypeContext) ?*const ZirBridge {
        return self.source.zirBridge();
    }

    // =========================================================================
    // Declaration Queries
    // =========================================================================

    /// Find type information for a declaration by name.
    pub fn getDeclType(self: *TypeContext, name: []const u8) ?TypeInfo {
        return self.source.findDeclType(name);
    }

    /// Find full declaration information by name.
    pub fn getDecl(self: *TypeContext, name: []const u8) ?DeclInfo {
        return self.source.findDecl(name);
    }

    /// Check if a declaration exists.
    pub fn hasDecl(self: *TypeContext, name: []const u8) bool {
        return self.source.findDecl(name) != null;
    }

    /// Check if a declaration is a function.
    pub fn isDeclFunction(self: *TypeContext, name: []const u8) bool {
        return self.source.isDeclFunction(name);
    }

    /// Check if a declaration is a type (struct, enum, union, type).
    pub fn isDeclType(self: *TypeContext, name: []const u8) bool {
        return self.source.isDeclType(name);
    }

    /// Check if a declaration is public.
    pub fn isDeclPublic(self: *TypeContext, name: []const u8) bool {
        return self.source.isDeclPublic(name);
    }

    /// Check if a declaration is a constant.
    pub fn isDeclConst(self: *TypeContext, name: []const u8) bool {
        return self.source.isDeclConst(name);
    }

    /// Get all declarations.
    pub fn getAllDecls(self: *TypeContext, result: *std.ArrayList(DeclInfo)) !void {
        const count = self.source.getDeclCount();
        for (0..count) |i| {
            if (self.source.getDecl(i)) |decl| {
                try result.append(self.allocator, decl);
            }
        }
    }

    // =========================================================================
    // AST Node Type Queries
    // =========================================================================

    /// Get type information for an AST node by index.
    /// Uses caching to avoid repeated lookups.
    pub fn getNodeType(self: *TypeContext, ast_node: u32) ?TypeInfo {
        // Check cache first
        if (self.node_type_cache.get(ast_node)) |cached| {
            return cached;
        }

        // Try to find type from ZirBridge
        const bridge = self.source.zirBridge() orelse return null;

        // Search declarations for matching AST node
        const count = bridge.getDeclCount();
        for (0..count) |i| {
            if (bridge.getDecl(i)) |decl| {
                if (decl.ast_node == ast_node) {
                    // Cache and return
                    self.node_type_cache.put(ast_node, decl.type_info) catch {};
                    return decl.type_info;
                }
            }
        }

        return null;
    }

    /// Cache a type for an AST node (useful when building CFG).
    pub fn cacheNodeType(self: *TypeContext, ast_node: u32, type_info: TypeInfo) void {
        self.node_type_cache.put(ast_node, type_info) catch {};
    }

    // =========================================================================
    // Type Kind Queries (convenience methods)
    // =========================================================================

    /// Check if a declaration has an error union type.
    pub fn isDeclErrorUnion(self: *TypeContext, name: []const u8) bool {
        const ti = self.getDeclType(name) orelse return false;
        return ti.kind == .error_union;
    }

    /// Check if a declaration has an optional type.
    pub fn isDeclOptional(self: *TypeContext, name: []const u8) bool {
        const ti = self.getDeclType(name) orelse return false;
        return ti.kind == .optional;
    }

    /// Check if a declaration has a pointer type.
    pub fn isDeclPointer(self: *TypeContext, name: []const u8) bool {
        const ti = self.getDeclType(name) orelse return false;
        return ti.kind == .pointer;
    }

    /// Check if a declaration has an integer type (signed or unsigned).
    pub fn isDeclInteger(self: *TypeContext, name: []const u8) bool {
        const ti = self.getDeclType(name) orelse return false;
        return ti.kind == .int or ti.kind == .uint;
    }

    /// Check if a declaration has a slice type.
    pub fn isDeclSlice(self: *TypeContext, name: []const u8) bool {
        const ti = self.getDeclType(name) orelse return false;
        return ti.kind == .slice;
    }

    // =========================================================================
    // Identifier Classification (for rules like identifier-style)
    // =========================================================================

    /// Classify an identifier as a type, function, constant, or variable.
    pub const IdentifierKind = enum {
        type_decl, // struct, enum, union, type alias
        function,
        constant,
        variable,
        unknown,
    };

    /// Classify an identifier by name.
    pub fn classifyIdentifier(self: *TypeContext, name: []const u8) IdentifierKind {
        const decl = self.getDecl(name) orelse return .unknown;

        if (decl.is_fn) return .function;

        switch (decl.type_info.kind) {
            .@"struct", .@"enum", .@"union", .type_type => return .type_decl,
            else => {},
        }

        if (decl.is_const) return .constant;
        return .variable;
    }

    /// Check if an identifier should use PascalCase (types).
    pub fn shouldBePascalCase(self: *TypeContext, name: []const u8) bool {
        return self.classifyIdentifier(name) == .type_decl;
    }

    /// Check if an identifier should use camelCase (functions, methods).
    pub fn shouldBeCamelCase(self: *TypeContext, name: []const u8) bool {
        return self.classifyIdentifier(name) == .function;
    }

    /// Check if an identifier should use snake_case (variables, constants).
    pub fn shouldBeSnakeCase(self: *TypeContext, name: []const u8) bool {
        const kind = self.classifyIdentifier(name);
        return kind == .constant or kind == .variable;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TypeContext basic creation" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    try std.testing.expect(ctx.isAvailable());
}

test "TypeContext getDeclType" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    const ti = ctx.getDeclType("x");
    try std.testing.expect(ti != null);
    if (ti) |t| {
        try std.testing.expectEqual(TypeInfo.TypeKind.int, t.kind);
    }
}

test "TypeContext classifyIdentifier" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\pub fn myFunc() void {}
        \\const MY_CONST: i32 = 42;
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    try std.testing.expectEqual(TypeContext.IdentifierKind.function, ctx.classifyIdentifier("myFunc"));
    try std.testing.expectEqual(TypeContext.IdentifierKind.constant, ctx.classifyIdentifier("MY_CONST"));
    try std.testing.expectEqual(TypeContext.IdentifierKind.unknown, ctx.classifyIdentifier("nonexistent"));
}

test "TypeContext caseRecommendations" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\pub fn myFunc() void {}
        \\const MY_CONST: i32 = 42;
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    try std.testing.expect(ctx.shouldBeCamelCase("myFunc"));
    try std.testing.expect(!ctx.shouldBePascalCase("myFunc"));
    try std.testing.expect(ctx.shouldBeSnakeCase("MY_CONST"));
}

test "TypeContext nodeTypeCache" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    // Manually cache a type
    const ti = TypeInfo.initInt(64, false);
    ctx.cacheNodeType(100, ti);

    // Retrieve from cache
    const cached = ctx.getNodeType(100);
    try std.testing.expect(cached != null);
    if (cached) |c| {
        try std.testing.expectEqual(TypeInfo.TypeKind.uint, c.kind);
        try std.testing.expectEqual(@as(u16, 64), c.size_bits);
    }
}

test "TypeContext type kind queries" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\const int_val: i32 = 42;
        \\const ptr_val: *i32 = undefined;
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    try std.testing.expect(ctx.isDeclInteger("int_val"));
    try std.testing.expect(!ctx.isDeclPointer("int_val"));
    try std.testing.expect(!ctx.isDeclOptional("int_val"));
}
