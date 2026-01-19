const std = @import("std");

/// Severity levels for diagnostics
pub const Severity = enum {
    /// Informational hint, does not indicate a problem
    hint,
    /// Warning that may indicate a potential issue
    warning,
    /// Error that indicates a definite problem
    err,

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .hint => "hint",
            .warning => "warning",
            .err => "error",
        };
    }
};

/// A location in source code (line and column are 1-based)
pub const Location = struct {
    line: usize,
    column: usize,

    pub fn init(line: usize, column: usize) Location {
        return .{ .line = line, .column = column };
    }
};

/// A range in source code defined by start and end locations
pub const SourceRange = struct {
    start: Location,
    end: Location,

    pub fn init(start: Location, end: Location) SourceRange {
        return .{ .start = start, .end = end };
    }

    pub fn fromSingleLocation(loc: Location) SourceRange {
        return .{ .start = loc, .end = loc };
    }
};

/// A structured diagnostic representing an issue found during analysis
pub const Diagnostic = struct {
    file_path: []const u8,
    rule_id: []const u8,
    severity: Severity,
    message: []const u8,
    range: SourceRange,

    pub fn init(
        file_path: []const u8,
        rule_id: []const u8,
        severity: Severity,
        message: []const u8,
        range: SourceRange,
    ) Diagnostic {
        return .{
            .file_path = file_path,
            .rule_id = rule_id,
            .severity = severity,
            .message = message,
            .range = range,
        };
    }

    pub fn initAtLocation(
        file_path: []const u8,
        rule_id: []const u8,
        severity: Severity,
        message: []const u8,
        line: usize,
        column: usize,
    ) Diagnostic {
        const loc = Location.init(line, column);
        return init(file_path, rule_id, severity, message, SourceRange.fromSingleLocation(loc));
    }

    pub fn format(self: Diagnostic, writer: anytype) !void {
        try writer.print("{s}:{d}:{d}: {s}: [{s}] {s}\n", .{
            self.file_path,
            self.range.start.line,
            self.range.start.column,
            self.severity.toString(),
            self.rule_id,
            self.message,
        });
    }
};

/// Maps byte offsets in source content to line/column locations.
/// Uses 1-based line and column numbers.
pub const LocationMapper = struct {
    content: []const u8,
    line_offsets: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) !LocationMapper {
        var offsets: std.ArrayList(usize) = .empty;
        errdefer offsets.deinit(allocator);

        try offsets.append(allocator, 0);

        for (content, 0..) |c, i| {
            if (c == '\n') {
                try offsets.append(allocator, i + 1);
            }
        }

        return .{
            .content = content,
            .line_offsets = try offsets.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LocationMapper) void {
        self.allocator.free(self.line_offsets);
    }

    pub fn byteToLocation(self: *const LocationMapper, byte_offset: usize) Location {
        const line = self.byteToLine(byte_offset);
        const line_start = self.line_offsets[line - 1];
        const column = byte_offset - line_start + 1;
        return Location.init(line, column);
    }

    fn byteToLine(self: *const LocationMapper, byte_offset: usize) usize {
        var low: usize = 0;
        var high: usize = self.line_offsets.len;

        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.line_offsets[mid] <= byte_offset) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }

    pub fn byteRangeToSourceRange(
        self: *const LocationMapper,
        start_byte: usize,
        end_byte: usize,
    ) SourceRange {
        return SourceRange.init(
            self.byteToLocation(start_byte),
            self.byteToLocation(end_byte),
        );
    }
};

test "Severity.toString" {
    const testing = std.testing;
    try testing.expectEqualStrings("hint", Severity.hint.toString());
    try testing.expectEqualStrings("warning", Severity.warning.toString());
    try testing.expectEqualStrings("error", Severity.err.toString());
}

test "Location initialization" {
    const loc = Location.init(10, 5);
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 10), loc.line);
    try testing.expectEqual(@as(usize, 5), loc.column);
}

test "SourceRange from single location" {
    const loc = Location.init(3, 7);
    const range = SourceRange.fromSingleLocation(loc);
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 3), range.start.line);
    try testing.expectEqual(@as(usize, 7), range.start.column);
    try testing.expectEqual(@as(usize, 3), range.end.line);
    try testing.expectEqual(@as(usize, 7), range.end.column);
}

test "Diagnostic formatting" {
    const testing = std.testing;

    const diag = Diagnostic.init(
        "test.zig",
        "empty-catch",
        .err,
        "Empty catch block detected",
        SourceRange.init(Location.init(5, 10), Location.init(5, 15)),
    );

    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try diag.format(stream.writer());

    const expected = "test.zig:5:10: error: [empty-catch] Empty catch block detected\n";
    try testing.expectEqualStrings(expected, stream.getWritten());
}

test "Diagnostic initAtLocation" {
    const testing = std.testing;

    const diag = Diagnostic.initAtLocation(
        "foo.zig",
        "test-rule",
        .warning,
        "Test message",
        3,
        12,
    );

    try testing.expectEqualStrings("foo.zig", diag.file_path);
    try testing.expectEqualStrings("test-rule", diag.rule_id);
    try testing.expectEqual(Severity.warning, diag.severity);
    try testing.expectEqual(@as(usize, 3), diag.range.start.line);
    try testing.expectEqual(@as(usize, 12), diag.range.start.column);
}

test "LocationMapper single line" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "const x = 42;";
    var mapper = try LocationMapper.init(allocator, content);
    defer mapper.deinit();

    const loc0 = mapper.byteToLocation(0);
    try testing.expectEqual(@as(usize, 1), loc0.line);
    try testing.expectEqual(@as(usize, 1), loc0.column);

    const loc6 = mapper.byteToLocation(6);
    try testing.expectEqual(@as(usize, 1), loc6.line);
    try testing.expectEqual(@as(usize, 7), loc6.column);
}

test "LocationMapper multiple lines" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "line1\nline2\nline3";
    var mapper = try LocationMapper.init(allocator, content);
    defer mapper.deinit();

    const loc_line1 = mapper.byteToLocation(0);
    try testing.expectEqual(@as(usize, 1), loc_line1.line);
    try testing.expectEqual(@as(usize, 1), loc_line1.column);

    const loc_line2_start = mapper.byteToLocation(6);
    try testing.expectEqual(@as(usize, 2), loc_line2_start.line);
    try testing.expectEqual(@as(usize, 1), loc_line2_start.column);

    const loc_line2_mid = mapper.byteToLocation(8);
    try testing.expectEqual(@as(usize, 2), loc_line2_mid.line);
    try testing.expectEqual(@as(usize, 3), loc_line2_mid.column);

    const loc_line3 = mapper.byteToLocation(12);
    try testing.expectEqual(@as(usize, 3), loc_line3.line);
    try testing.expectEqual(@as(usize, 1), loc_line3.column);
}

test "LocationMapper byteRangeToSourceRange" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "line1\nline2\nline3";
    var mapper = try LocationMapper.init(allocator, content);
    defer mapper.deinit();

    const range = mapper.byteRangeToSourceRange(6, 10);

    try testing.expectEqual(@as(usize, 2), range.start.line);
    try testing.expectEqual(@as(usize, 1), range.start.column);
    try testing.expectEqual(@as(usize, 2), range.end.line);
    try testing.expectEqual(@as(usize, 5), range.end.column);
}

test "LocationMapper empty content" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "";
    var mapper = try LocationMapper.init(allocator, content);
    defer mapper.deinit();

    try testing.expectEqual(@as(usize, 1), mapper.line_offsets.len);
}

test "LocationMapper handles trailing newline" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "line1\n";
    var mapper = try LocationMapper.init(allocator, content);
    defer mapper.deinit();

    const loc_line1 = mapper.byteToLocation(0);
    try testing.expectEqual(@as(usize, 1), loc_line1.line);

    const loc_after_newline = mapper.byteToLocation(6);
    try testing.expectEqual(@as(usize, 2), loc_after_newline.line);
    try testing.expectEqual(@as(usize, 1), loc_after_newline.column);
}
