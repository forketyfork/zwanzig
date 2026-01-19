const std = @import("std");

pub const Source = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: [:0]const u8,

    cached_ast: ?std.zig.Ast = null,

    pub fn init(allocator: std.mem.Allocator, file_path: []const u8, content: [:0]const u8) Source {
        return Source{
            .allocator = allocator,
            .file_path = file_path,
            .content = content,
            .cached_ast = null,
        };
    }

    pub fn deinit(self: *Source) void {
        if (self.cached_ast) |*ast_ptr| {
            ast_ptr.deinit(self.allocator);
        }
    }

    pub fn getContent(self: *const Source) []const u8 {
        return self.content;
    }

    pub fn getFilePath(self: *const Source) []const u8 {
        return self.file_path;
    }

    pub fn tokens(self: *Source) !std.zig.Ast.TokenList.Slice {
        const ast_result = try self.ast();
        return ast_result.tokens;
    }

    pub fn ast(self: *Source) !*const std.zig.Ast {
        if (self.cached_ast == null) {
            const parsed = try std.zig.Ast.parse(self.allocator, self.content, .zig);
            self.cached_ast = parsed;
        }
        return &self.cached_ast.?;
    }
};

test "Source basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    try testing.expectEqualStrings("test.zig", source.getFilePath());
    try testing.expectEqualStrings(code, source.getContent());
}

test "Source tokens caching via AST" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const tokens1 = try source.tokens();
    const tokens2 = try source.tokens();

    try testing.expect(tokens1.len == tokens2.len);
    try testing.expect(tokens1.len > 0);
    try testing.expect(source.cached_ast != null);
}

test "Source AST caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const ast1 = try source.ast();
    const ast2 = try source.ast();

    try testing.expect(ast1 == ast2);
    try testing.expect(ast1.nodes.len == ast2.nodes.len);
    try testing.expect(ast1.tokens.len == ast2.tokens.len);
}

test "Source AST parsing valid code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    const x = 42;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const parsed_ast = try source.ast();
    try testing.expect(parsed_ast.nodes.len > 0);
    try testing.expect(parsed_ast.tokens.len > 0);
}

test "Source tokens and AST share data" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const parsed_ast = try source.ast();
    const tok = try source.tokens();

    try testing.expect(tok.len == parsed_ast.tokens.len);
}
