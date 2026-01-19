const std = @import("std");
const diagnostic = @import("diagnostic.zig");
pub const Location = diagnostic.Location;
pub const SourceRange = diagnostic.SourceRange;
pub const LocationMapper = diagnostic.LocationMapper;

pub const Source = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: [:0]const u8,

    cached_ast: ?std.zig.Ast = null,
    cached_location_mapper: ?LocationMapper = null,

    pub fn init(allocator: std.mem.Allocator, file_path: []const u8, content: [:0]const u8) Source {
        return Source{
            .allocator = allocator,
            .file_path = file_path,
            .content = content,
            .cached_ast = null,
            .cached_location_mapper = null,
        };
    }

    pub fn deinit(self: *Source) void {
        if (self.cached_ast) |*ast_ptr| {
            ast_ptr.deinit(self.allocator);
        }
        if (self.cached_location_mapper) |*mapper| {
            mapper.deinit();
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

    pub fn locationMapper(self: *Source) !*const LocationMapper {
        if (self.cached_location_mapper == null) {
            self.cached_location_mapper = try LocationMapper.init(self.allocator, self.content);
        }
        return &self.cached_location_mapper.?;
    }

    pub fn byteToLocation(self: *Source, byte_offset: usize) !Location {
        const mapper = try self.locationMapper();
        return mapper.byteToLocation(byte_offset);
    }

    pub fn byteRangeToSourceRange(self: *Source, start_byte: usize, end_byte: usize) !SourceRange {
        const mapper = try self.locationMapper();
        return mapper.byteRangeToSourceRange(start_byte, end_byte);
    }

    pub fn tokenLocation(self: *Source, token_index: u32) !Location {
        const parsed_ast = try self.ast();
        const token_starts = parsed_ast.tokens.items(.start);
        if (token_index >= token_starts.len) {
            return Location.init(1, 1);
        }
        const byte_offset = token_starts[token_index];
        return self.byteToLocation(byte_offset);
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

test "Source byteToLocation single line" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const loc0 = try source.byteToLocation(0);
    try testing.expectEqual(@as(usize, 1), loc0.line);
    try testing.expectEqual(@as(usize, 1), loc0.column);

    const loc6 = try source.byteToLocation(6);
    try testing.expectEqual(@as(usize, 1), loc6.line);
    try testing.expectEqual(@as(usize, 7), loc6.column);
}

test "Source byteToLocation multiple lines" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 1;\nconst y = 2;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const loc_line1 = try source.byteToLocation(0);
    try testing.expectEqual(@as(usize, 1), loc_line1.line);
    try testing.expectEqual(@as(usize, 1), loc_line1.column);

    const loc_line2 = try source.byteToLocation(13);
    try testing.expectEqual(@as(usize, 2), loc_line2.line);
    try testing.expectEqual(@as(usize, 1), loc_line2.column);
}

test "Source locationMapper caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    try testing.expect(source.cached_location_mapper == null);

    const mapper1 = try source.locationMapper();
    try testing.expect(source.cached_location_mapper != null);

    const mapper2 = try source.locationMapper();
    try testing.expect(mapper1 == mapper2);
}

test "Source tokenLocation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const loc = try source.tokenLocation(0);
    try testing.expectEqual(@as(usize, 1), loc.line);
    try testing.expectEqual(@as(usize, 1), loc.column);
}

test "Source byteRangeToSourceRange" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const range = try source.byteRangeToSourceRange(6, 7);
    try testing.expectEqual(@as(usize, 1), range.start.line);
    try testing.expectEqual(@as(usize, 7), range.start.column);
    try testing.expectEqual(@as(usize, 1), range.end.line);
    try testing.expectEqual(@as(usize, 8), range.end.column);
}
