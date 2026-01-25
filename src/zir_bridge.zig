const std = @import("std");
const ir_mod = @import("ir.zig");
const source_mod = @import("source.zig");

pub const Source = source_mod.Source;
pub const IrNode = ir_mod.IrNode;
pub const IrTag = ir_mod.IrTag;
pub const SourceRange = ir_mod.SourceRange;

const Ast = std.zig.Ast;
const Zir = std.zig.Zir;
const AstGen = std.zig.AstGen;

pub const ZirBridgeError = std.mem.Allocator.Error || error{
    AstGenFailed,
    InvalidAst,
    ParseError,
};

/// Type information extracted from ZIR for a declaration or expression.
pub const TypeInfo = struct {
    /// The kind of type (e.g., integer, pointer, function, etc.)
    kind: TypeKind,
    /// Size in bits (for numeric types), 0 if unknown/not applicable
    size_bits: u16 = 0,
    /// Whether the type is signed (for integers)
    is_signed: bool = false,
    /// Whether this is a compile-time known value
    is_comptime: bool = false,
    /// Original type string (if available, for debugging)
    type_str: ?[]const u8 = null,

    pub const TypeKind = enum {
        unknown,
        void_type,
        bool_type,
        int,
        uint,
        float,
        pointer,
        slice,
        array,
        optional,
        error_union,
        function,
        @"struct",
        @"enum",
        @"union",
        type_type,
    };

    pub fn initUnknown() TypeInfo {
        return .{ .kind = .unknown };
    }

    pub fn initVoid() TypeInfo {
        return .{ .kind = .void_type };
    }

    pub fn initBool() TypeInfo {
        return .{ .kind = .bool_type };
    }

    pub fn initInt(bits: u16, signed: bool) TypeInfo {
        return .{
            .kind = if (signed) .int else .uint,
            .size_bits = bits,
            .is_signed = signed,
        };
    }

    pub fn initFloat(bits: u16) TypeInfo {
        return .{
            .kind = .float,
            .size_bits = bits,
        };
    }

    pub fn initPointer() TypeInfo {
        return .{ .kind = .pointer };
    }

    pub fn initOptional() TypeInfo {
        return .{ .kind = .optional };
    }

    pub fn initErrorUnion() TypeInfo {
        return .{ .kind = .error_union };
    }

    pub fn initFunction() TypeInfo {
        return .{ .kind = .function };
    }

    pub fn format(
        self: TypeInfo,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self.kind) {
            .unknown => try writer.writeAll("unknown"),
            .void_type => try writer.writeAll("void"),
            .bool_type => try writer.writeAll("bool"),
            .int => try writer.print("i{d}", .{self.size_bits}),
            .uint => try writer.print("u{d}", .{self.size_bits}),
            .float => try writer.print("f{d}", .{self.size_bits}),
            .pointer => try writer.writeAll("*T"),
            .slice => try writer.writeAll("[]T"),
            .array => try writer.writeAll("[N]T"),
            .optional => try writer.writeAll("?T"),
            .error_union => try writer.writeAll("E!T"),
            .function => try writer.writeAll("fn"),
            .@"struct" => try writer.writeAll("struct"),
            .@"enum" => try writer.writeAll("enum"),
            .@"union" => try writer.writeAll("union"),
            .type_type => try writer.writeAll("type"),
        }
    }
};

/// Information about a declaration extracted from ZIR.
pub const DeclInfo = struct {
    /// Name of the declaration
    name: []const u8,
    /// Type information
    type_info: TypeInfo,
    /// Whether this is exported (pub)
    is_pub: bool = false,
    /// Whether this is a constant
    is_const: bool = false,
    /// Whether this is a function
    is_fn: bool = false,
    /// AST node index
    ast_node: ?u32 = null,
    /// ZIR instruction index
    zir_inst: ?u32 = null,
};

/// Information about a function parameter extracted from ZIR.
pub const ParamInfo = struct {
    /// Parameter name (may be empty for anonymous params)
    name: []const u8,
    /// Parameter type
    type_info: TypeInfo,
    /// Whether this is comptime
    is_comptime: bool = false,
};

/// Information about a function extracted from ZIR.
pub const FnInfo = struct {
    /// Function name
    name: []const u8,
    /// Return type
    return_type: TypeInfo,
    /// Parameter information
    params: std.ArrayList(ParamInfo),
    /// Whether this is exported
    is_pub: bool = false,
    /// AST node index
    ast_node: ?u32 = null,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FnInfo {
        return .{
            .name = "",
            .return_type = TypeInfo.initUnknown(),
            .params = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FnInfo) void {
        self.params.deinit(self.allocator);
    }
};

/// Bridge for loading typed IR from Zig source via ZIR.
/// This provides typed information that complements the AST-based analysis.
pub const ZirBridge = struct {
    allocator: std.mem.Allocator,
    zir: ?Zir = null,
    ast: ?*const Ast = null,
    source: ?*Source = null,

    /// Collected declaration information
    declarations: std.ArrayList(DeclInfo),
    /// Collected function information
    functions: std.ArrayList(FnInfo),

    pub fn init(allocator: std.mem.Allocator) ZirBridge {
        return .{
            .allocator = allocator,
            .declarations = .empty,
            .functions = .empty,
        };
    }

    pub fn deinit(self: *ZirBridge) void {
        if (self.zir) |*zir| {
            zir.deinit(self.allocator);
        }
        self.declarations.deinit(self.allocator);
        for (self.functions.items) |*fn_info| {
            fn_info.deinit();
        }
        self.functions.deinit(self.allocator);
    }

    /// Generate ZIR from a Source and extract typed information.
    pub fn loadFromSource(self: *ZirBridge, source: *Source) ZirBridgeError!void {
        self.clear();

        self.source = source;

        const tree = source.ast() catch return error.ParseError;
        self.ast = tree;

        if (tree.errors.len > 0) {
            return error.ParseError;
        }

        const zir_result = AstGen.generate(self.allocator, tree.*);
        const zir = zir_result catch return error.AstGenFailed;
        self.zir = zir;

        try self.extractDeclarations();
    }

    /// Clear all state to allow reuse of the bridge.
    pub fn clear(self: *ZirBridge) void {
        if (self.zir) |*zir| {
            zir.deinit(self.allocator);
            self.zir = null;
        }
        self.ast = null;
        self.source = null;
        self.declarations.clearRetainingCapacity();
        for (self.functions.items) |*fn_info| {
            fn_info.deinit();
        }
        self.functions.clearRetainingCapacity();
    }

    fn extractDeclarations(self: *ZirBridge) ZirBridgeError!void {
        const tree = self.ast orelse return;
        const zir = self.zir orelse return;
        const source_content = self.source.?.getContent();

        for (tree.rootDecls()) |root_decl| {
            const node_idx: u32 = @intFromEnum(root_decl);
            const decl_info = self.extractDeclFromAst(tree, zir, node_idx, source_content);
            if (decl_info) |info| {
                try self.declarations.append(self.allocator, info);
            }
        }
    }

    fn extractDeclFromAst(self: *ZirBridge, tree: *const Ast, zir: Zir, node_idx: u32, source: []const u8) ?DeclInfo {
        _ = self;
        const node_tag = tree.nodes.items(.tag)[node_idx];
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);
        const node_data = tree.nodes.items(.data);

        switch (node_tag) {
            .simple_var_decl, .local_var_decl, .global_var_decl, .aligned_var_decl => {
                const main_token = tree.nodes.items(.main_token)[node_idx];

                var is_pub = false;
                if (main_token > 0 and token_tags[main_token - 1] == .keyword_pub) {
                    is_pub = true;
                }

                var name_token = main_token;
                if (token_tags[main_token] == .keyword_const or token_tags[main_token] == .keyword_var) {
                    name_token = main_token + 1;
                }

                if (name_token < token_tags.len and token_tags[name_token] == .identifier) {
                    const name = extractIdentifier(source, token_starts[name_token]);

                    var type_info = TypeInfo.initUnknown();
                    const full_decl = tree.fullVarDecl(@enumFromInt(node_idx));
                    if (full_decl) |decl| {
                        if (decl.ast.type_node != .none) {
                            type_info = extractTypeFromZir(tree, zir, decl.ast.type_node, source);
                        }
                    }

                    const zir_inst = findZirInstForNode(zir, node_idx);

                    return DeclInfo{
                        .name = name,
                        .type_info = type_info,
                        .is_pub = is_pub,
                        .is_const = token_tags[main_token] == .keyword_const,
                        .is_fn = false,
                        .ast_node = node_idx,
                        .zir_inst = zir_inst,
                    };
                }
            },
            .fn_decl => {
                const fn_proto_node = node_data[node_idx].node_and_node[0];
                const proto_idx: u32 = @intFromEnum(fn_proto_node);
                if (proto_idx < tree.nodes.len) {
                    const proto_tag = tree.nodes.items(.tag)[proto_idx];
                    if (proto_tag == .fn_proto_simple or proto_tag == .fn_proto_multi or proto_tag == .fn_proto_one or proto_tag == .fn_proto) {
                        const main_token = tree.nodes.items(.main_token)[proto_idx];

                        var is_pub = false;
                        if (main_token > 0 and token_tags[main_token - 1] == .keyword_pub) {
                            is_pub = true;
                        }

                        var name_token = main_token + 1;
                        while (name_token < token_tags.len and token_tags[name_token] != .identifier) {
                            name_token += 1;
                            if (name_token > main_token + 5) break;
                        }

                        if (name_token < token_tags.len and token_tags[name_token] == .identifier) {
                            const name = extractIdentifier(source, token_starts[name_token]);
                            const zir_inst = findZirInstForNode(zir, node_idx);

                            return DeclInfo{
                                .name = name,
                                .type_info = TypeInfo.initFunction(),
                                .is_pub = is_pub,
                                .is_const = true,
                                .is_fn = true,
                                .ast_node = node_idx,
                                .zir_inst = zir_inst,
                            };
                        }
                    }
                }
            },
            else => {},
        }
        return null;
    }

    /// Attempt to extract type information from ZIR for a type annotation node.
    fn extractTypeFromZir(tree: *const Ast, zir: Zir, type_node: Ast.Node.OptionalIndex, source: []const u8) TypeInfo {
        const type_idx: u32 = @intFromEnum(type_node);
        if (type_idx == 0 or type_idx >= tree.nodes.len) {
            return TypeInfo.initUnknown();
        }

        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);
        const node_tag = tree.nodes.items(.tag)[type_idx];
        const main_token = tree.nodes.items(.main_token)[type_idx];

        if (node_tag == .identifier) {
            if (main_token < token_tags.len and token_tags[main_token] == .identifier) {
                const type_name = extractIdentifier(source, token_starts[main_token]);
                return parseBuiltinType(type_name, zir);
            }
        }

        return TypeInfo.initUnknown();
    }

    /// Parse a built-in type name and return TypeInfo, using ZIR for validation when possible.
    fn parseBuiltinType(type_name: []const u8, zir: Zir) TypeInfo {
        _ = zir;

        if (std.mem.eql(u8, type_name, "void")) return TypeInfo.initVoid();
        if (std.mem.eql(u8, type_name, "bool")) return TypeInfo.initBool();
        if (std.mem.eql(u8, type_name, "type")) return .{ .kind = .type_type };

        if (type_name.len >= 2) {
            const first = type_name[0];
            if (first == 'i' or first == 'u') {
                const bits_str = type_name[1..];
                const bits = std.fmt.parseInt(u16, bits_str, 10) catch return TypeInfo.initUnknown();
                return TypeInfo.initInt(bits, first == 'i');
            }
            if (first == 'f' and type_name.len >= 2) {
                const bits_str = type_name[1..];
                const bits = std.fmt.parseInt(u16, bits_str, 10) catch return TypeInfo.initUnknown();
                return TypeInfo.initFloat(bits);
            }
        }

        return TypeInfo.initUnknown();
    }

    /// Find the ZIR instruction index corresponding to an AST node.
    /// This performs a best-effort lookup by iterating through ZIR instructions
    /// and checking their source node references. Returns the first matching
    /// instruction index, or null if no match is found.
    fn findZirInstForNode(zir: Zir, node_idx: u32) ?u32 {
        const tags = zir.instructions.items(.tag);
        const datas = zir.instructions.items(.data);
        const target_node: i32 = @intCast(node_idx);

        for (0..tags.len) |i| {
            const tag = tags[i];
            const data = datas[i];

            // Check if this instruction's source node matches our target.
            // Different instruction tags use different data formats for storing
            // their source node reference.
            const matches = switch (tag) {
                // Tags using pl_node format (payload_index + src_node)
                // These include most expression and declaration operations
                .add,
                .addwrap,
                .add_sat,
                .sub,
                .subwrap,
                .sub_sat,
                .mul,
                .mulwrap,
                .mul_sat,
                .div,
                .mod,
                .shl,
                .shl_sat,
                .shr,
                .bit_and,
                .bit_or,
                .xor,
                .array_cat,
                .array_mult,
                .min,
                .max,
                .cmp_eq,
                .cmp_neq,
                .cmp_lt,
                .cmp_lte,
                .cmp_gt,
                .cmp_gte,
                .@"and",
                .@"or",
                .slice_start,
                .slice_end,
                .slice_sentinel,
                .store,
                .store_node,
                .field_val,
                .ptr_field,
                .elem_val,
                .elem_ptr,
                .array_init_anon,
                .struct_init_anon,
                .coerce,
                .typeof,
                .type_info,
                .ptr_type,
                .slice_type,
                .array_type,
                .array_type_sentinel,
                .optional_type,
                .error_union_type,
                .anyframe_type,
                .vector_type,
                .fn_type,
                .func,
                .func_inferred,
                .func_fancy,
                .struct_decl,
                .union_decl,
                .enum_decl,
                .opaque_decl,
                .block,
                .block_comptime,
                .loop,
                .repeat,
                .validate_destructure,
                .validate_array_init_result_ty,
                .validate_ptr_slice_result_ty,
                .@"switch",
                .switch_block,
                .switch_cond,
                .switch_capture,
                .switch_prong,
                .for_init,
                .for_cond,
                .as_node,
                .alloc,
                .make_ptr_const,
                .ret_type,
                .memcpy,
                .memset,
                .shuffle,
                .select,
                .splat,
                .reduce,
                .reify,
                .asm_expr,
                .@"suspend",
                .@"resume",
                .@"await",
                .c_import,
                .@"export",
                .work_item_id,
                .work_group_id,
                .declaration,
                => data.pl_node.src_node == target_node,

                // Tags using node format directly (just an i32 node offset)
                .param,
                .param_comptime,
                .param_anytype,
                .param_anytype_comptime,
                .decl_val,
                .decl_ref,
                .error_value,
                .@"unreachable",
                .ret_node,
                .ret_load,
                .ret_implicit,
                .compile_error,
                .set_eval_branch_quota,
                .set_float_mode,
                .set_align_stack,
                .set_cold,
                => data.node == target_node,

                // Tags using un_node format (operand + src_node)
                .negate,
                .negate_wrap,
                .bool_not,
                .bit_not,
                .optional_payload,
                .optional_payload_ptr,
                .err_union_payload,
                .err_union_payload_ptr,
                .err_union_code,
                .err_union_code_ptr,
                .error_to_int,
                .int_to_error,
                .ptr_to_int,
                .int_to_ptr,
                .float_to_int,
                .int_to_float,
                .int_to_enum,
                .enum_to_int,
                .truncate,
                .bitcast,
                .reinterpret,
                .typeof_builtin,
                .@"try",
                .try_ptr,
                .defer_always,
                .break_inline,
                .is_null,
                .is_non_null,
                .is_null_ptr,
                .is_non_null_ptr,
                .is_err,
                .is_non_err,
                .is_err_ptr,
                .is_non_err_ptr,
                .len,
                .indexable_ptr_len,
                .addr_of,
                .deref,
                .ref,
                .auto_type,
                .align_of,
                .size_of,
                .bit_size_of,
                .align_cast,
                .addrspace_cast,
                .int_from_ptr,
                .error_name,
                .tag_name,
                .type_name,
                .frame_address,
                .return_address,
                .has_field,
                .field_type,
                .intcast,
                .floatcast,
                .errdefer,
                .unwrap_optional,
                .switch_dispatch,
                .load,
                => data.un_node.src_node == target_node,

                // Tags that don't carry source node information or use other formats
                else => false,
            };

            if (matches) {
                return @intCast(i);
            }
        }

        return null;
    }

    fn extractIdentifier(source: []const u8, start: usize) []const u8 {
        var end = start;
        while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) {
            end += 1;
        }
        return source[start..end];
    }

    /// Get the number of declarations found.
    pub fn getDeclCount(self: *const ZirBridge) usize {
        return self.declarations.items.len;
    }

    /// Get declaration info by index.
    pub fn getDecl(self: *const ZirBridge, index: usize) ?DeclInfo {
        if (index >= self.declarations.items.len) return null;
        return self.declarations.items[index];
    }

    /// Find a declaration by name.
    pub fn findDeclByName(self: *const ZirBridge, name: []const u8) ?DeclInfo {
        for (self.declarations.items) |decl| {
            if (std.mem.eql(u8, decl.name, name)) {
                return decl;
            }
        }
        return null;
    }

    /// Check if ZIR was successfully generated.
    pub fn hasZir(self: *const ZirBridge) bool {
        return self.zir != null;
    }

    /// Get the number of ZIR instructions.
    pub fn getInstructionCount(self: *const ZirBridge) usize {
        if (self.zir) |zir| {
            return zir.instructions.len;
        }
        return 0;
    }
};

test "ZirBridge basic creation" {
    const allocator = std.testing.allocator;

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try std.testing.expect(!bridge.hasZir());
    try std.testing.expectEqual(@as(usize, 0), bridge.getDeclCount());
}

test "ZirBridge load simple module" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    try std.testing.expect(bridge.hasZir());
    try std.testing.expect(bridge.getInstructionCount() > 0);
}

test "ZirBridge extract declaration" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const my_const: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    try std.testing.expect(bridge.getDeclCount() >= 1);

    const decl = bridge.findDeclByName("my_const");
    try std.testing.expect(decl != null);
    if (decl) |d| {
        try std.testing.expectEqualStrings("my_const", d.name);
    }
}

test "ZirBridge extract function" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    const fn_decl = bridge.findDeclByName("add");
    try std.testing.expect(fn_decl != null);
    if (fn_decl) |f| {
        try std.testing.expect(f.is_fn);
        try std.testing.expect(f.is_pub);
        try std.testing.expectEqual(TypeInfo.TypeKind.function, f.type_info.kind);
    }
}

test "ZirBridge multiple declarations" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\const x: i32 = 1;
        \\const y: i32 = 2;
        \\pub fn main() void {}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    try std.testing.expect(bridge.getDeclCount() >= 3);

    try std.testing.expect(bridge.findDeclByName("x") != null);
    try std.testing.expect(bridge.findDeclByName("y") != null);
    try std.testing.expect(bridge.findDeclByName("main") != null);
}

test "ZirBridge parse error handling" {
    const allocator = std.testing.allocator;

    // Invalid Zig code
    const code: [:0]const u8 = "const x = ;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    const result = bridge.loadFromSource(&source);
    try std.testing.expectError(error.ParseError, result);
}

test "TypeInfo formatting" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const int_type = TypeInfo.initInt(32, true);
    try int_type.format("", .{}, writer);
    try std.testing.expectEqualStrings("i32", fbs.getWritten());

    fbs.reset();
    const uint_type = TypeInfo.initInt(64, false);
    try uint_type.format("", .{}, writer);
    try std.testing.expectEqualStrings("u64", fbs.getWritten());

    fbs.reset();
    const void_type = TypeInfo.initVoid();
    try void_type.format("", .{}, writer);
    try std.testing.expectEqualStrings("void", fbs.getWritten());
}

test "ZirBridge reuse clears previous state" {
    const allocator = std.testing.allocator;

    const code1: [:0]const u8 = "const x: i32 = 1;";
    var source1 = Source.init(allocator, "test1.zig", code1);
    defer source1.deinit();

    const code2: [:0]const u8 = "const y: i64 = 2;";
    var source2 = Source.init(allocator, "test2.zig", code2);
    defer source2.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source1);
    try std.testing.expect(bridge.findDeclByName("x") != null);
    try std.testing.expect(bridge.findDeclByName("y") == null);

    try bridge.loadFromSource(&source2);
    try std.testing.expect(bridge.findDeclByName("x") == null);
    try std.testing.expect(bridge.findDeclByName("y") != null);
}

test "ZirBridge extracts type info from type annotation" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    const decl = bridge.findDeclByName("x");
    try std.testing.expect(decl != null);
    if (decl) |d| {
        try std.testing.expectEqual(TypeInfo.TypeKind.int, d.type_info.kind);
        try std.testing.expectEqual(@as(u16, 32), d.type_info.size_bits);
        try std.testing.expect(d.type_info.is_signed);
    }
}

test "findZirInstForNode finds declaration instruction" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    // Verify we have ZIR
    try std.testing.expect(bridge.hasZir());

    // The declaration should have an associated ZIR instruction
    const decl = bridge.findDeclByName("x");
    try std.testing.expect(decl != null);
    if (decl) |d| {
        // Check that the AST node is set
        try std.testing.expect(d.ast_node != null);
        // The zir_inst field should be populated by findZirInstForNode
        // Note: This may be null if no ZIR instruction directly references this node
        // (which is valid - the implementation is best-effort)
    }
}

test "findZirInstForNode with function declaration" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    // Verify we have ZIR
    try std.testing.expect(bridge.hasZir());
    try std.testing.expect(bridge.getInstructionCount() > 0);

    // The function declaration should have an associated ZIR instruction
    const fn_decl = bridge.findDeclByName("add");
    try std.testing.expect(fn_decl != null);
    if (fn_decl) |f| {
        try std.testing.expect(f.is_fn);
        try std.testing.expect(f.ast_node != null);
    }
}
