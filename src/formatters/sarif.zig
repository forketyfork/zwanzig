const CheckerManagerWithRules = @import("../checker.zig").CheckerManagerWithRules;
const Diagnostic = @import("../rule.zig").Diagnostic;

pub const SarifFormatter = struct {
    checker_manager: *const CheckerManagerWithRules,
    tool_version: []const u8,
    diagnostics: []const Diagnostic,

    pub fn init(
        checker_manager: *const CheckerManagerWithRules,
        tool_version: []const u8,
        diagnostics: []const Diagnostic,
    ) SarifFormatter {
        return .{
            .checker_manager = checker_manager,
            .tool_version = tool_version,
            .diagnostics = diagnostics,
        };
    }

    pub fn write(self: *SarifFormatter, writer: anytype) !void {
        try writer.writeAll("{\n");
        try writer.writeAll("  \"version\": \"2.1.0\",\n");
        try writer.writeAll("  \"$schema\": \"https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json\",\n");
        try writer.writeAll("  \"runs\": [\n");
        try writer.writeAll("    {\n");
        try writer.writeAll("      \"tool\": {\n");
        try writer.writeAll("        \"driver\": {\n");
        try writer.writeAll("          \"name\": \"Zwanzig\",\n");
        try writer.writeAll("          \"informationUri\": \"https://github.com/forketyfork/zwanzig\",\n");
        try writer.writeAll("          \"version\": ");
        try writeJsonString(writer, self.tool_version);
        try writer.writeAll(",\n");
        try writer.writeAll("          \"rules\": [\n");

        var first = true;
        for (self.checker_manager.checkers.items) |checker| {
            if (!first) try writer.writeAll(",\n");
            first = false;
            try writer.writeAll("            {\n");
            try writer.writeAll("              \"id\": ");
            try writeJsonString(writer, checker.name);
            try writer.writeAll(",\n");
            try writer.writeAll("              \"shortDescription\": {\n");
            try writer.writeAll("                \"text\": ");
            try writeJsonString(writer, checker.name);
            try writer.writeAll("\n");
            try writer.writeAll("              },\n");
            try writer.writeAll("              \"defaultConfiguration\": {\n");
            try writer.writeAll("                \"level\": ");
            try writeJsonString(writer, checker.default_severity.toSarifLevel());
            try writer.writeAll("\n");
            try writer.writeAll("              }\n");
            try writer.writeAll("            }");
        }

        for (self.checker_manager.adapted_rules.items) |rule| {
            if (!first) try writer.writeAll(",\n");
            first = false;
            try writer.writeAll("            {\n");
            try writer.writeAll("              \"id\": ");
            try writeJsonString(writer, rule.name);
            try writer.writeAll(",\n");
            try writer.writeAll("              \"shortDescription\": {\n");
            try writer.writeAll("                \"text\": ");
            try writeJsonString(writer, rule.name);
            try writer.writeAll("\n");
            try writer.writeAll("              }\n");
            try writer.writeAll("            }");
        }

        try writer.writeAll("\n");
        try writer.writeAll("          ]\n");
        try writer.writeAll("        }\n");
        try writer.writeAll("      },\n");
        try writer.writeAll("      \"results\": [\n");

        for (self.diagnostics, 0..) |diag, i| {
            try diag.writeSarif(writer);
            if (i < self.diagnostics.len - 1) {
                try writer.writeAll(",\n");
            } else {
                try writer.writeAll("\n");
            }
        }

        try writer.writeAll("      ]\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("  ]\n");
        try writer.writeAll("}\n");
    }
};

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}
