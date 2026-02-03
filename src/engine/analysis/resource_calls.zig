const std = @import("std");
const call_utils = @import("../../analysis/call_utils.zig");
const allocator_utils = @import("../../analysis/allocator_utils.zig");

pub fn mixin(comptime _Engine: type) type {
    return struct {
        const ResourceCallKind = enum {
            alloc,
            free,
            free_owned,
            open,
            close,
        };

        const ResourceCall = struct {
            kind: ResourceCallKind,
            target_expr: ?u32,
            call_node: u32,
        };

        pub fn resolveResourceCall(self: *_Engine, expr_node: u32) ?ResourceCall {
            const src = self.source orelse return null;
            const tree = src.ast() catch return null;
            return resolveResourceCallFromExpr(self, tree, expr_node);
        }

        pub fn isDefinitelyNonAlloc(self: *_Engine, expr_node: u32) bool {
            const src = self.source orelse return false;
            const tree = src.ast() catch return false;
            return isDefinitelyNonAllocExpr(self, tree, expr_node);
        }

        pub fn resolveResourceCallFromExpr(self: *_Engine, tree: *const std.zig.Ast, expr_node: u32) ?ResourceCall {
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);

            if (expr_node >= tags.len) return null;
            const tag = tags[expr_node];

            return switch (tag) {
                .call, .call_comma, .call_one, .call_one_comma => resolveResourceCallFromCall(self, tree, expr_node),
                .@"try" => resolveResourceCallFromExpr(self, tree, @intFromEnum(datas[expr_node].node)),
                .@"catch" => blk: {
                    const pair = datas[expr_node].node_and_node;
                    if (resolveResourceCallFromExpr(self, tree, @intFromEnum(pair[0]))) |call_info| {
                        break :blk call_info;
                    }
                    break :blk resolveResourceCallFromExpr(self, tree, @intFromEnum(pair[1]));
                },
                .unwrap_optional, .grouped_expression => resolveResourceCallFromExpr(self, tree, @intFromEnum(datas[expr_node].node_and_token[0])),
                .slice, .slice_open, .slice_sentinel => blk: {
                    const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse break :blk null;
                    break :blk resolveResourceCallFromExpr(self, tree, @intFromEnum(slice.ast.sliced));
                },
                else => null,
            };
        }

        pub fn resolveResourceCallFromCall(self: *_Engine, tree: *const std.zig.Ast, call_ast_node: u32) ?ResourceCall {
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);
            const token_tags = tree.tokens.items(.tag);

            if (call_ast_node >= tags.len) return null;
            const tag = tags[call_ast_node];

            var call_buf: [1]std.zig.Ast.Node.Index = undefined;
            const full_call = switch (tag) {
                .call, .call_comma, .call_one, .call_one_comma => tree.fullCall(&call_buf, @enumFromInt(call_ast_node)),
                else => return null,
            } orelse return null;

            const callee_node: u32 = @intFromEnum(full_call.ast.fn_expr);
            if (callee_node >= tags.len) return null;
            if (tags[callee_node] != .field_access) return null;

            const field_access_data = datas[callee_node].node_and_token;
            const base_node = @intFromEnum(field_access_data[0]);
            const field_token = field_access_data[1];
            if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return null;
            const field_name = tree.tokenSlice(field_token);

            const first_arg: ?u32 = if (full_call.ast.params.len > 0)
                @intFromEnum(full_call.ast.params[0])
            else
                null;

            // Priority 1: Config-driven resource models
            if (self.config) |config| {
                // Get return type info if available
                var return_type_str: ?[]const u8 = null;
                if (self.type_context) |type_ctx| {
                    if (type_ctx.getExpressionType(call_ast_node)) |ti| {
                        return_type_str = ti.type_str;
                    }
                }

                // Extract receiver type from the base expression
                const receiver_type = call_utils.getReceiverTypeName(self.type_context, tree, base_node);

                // Construct FQN from receiver.method
                const fqn = call_utils.constructFqn(tree, base_node, field_name, &self.fqn_buffer);

                // Match against config resource models
                if (config.matchResourceModel(field_name, receiver_type, return_type_str, fqn)) |model_kind| {
                    const kind: ResourceCallKind = switch (model_kind) {
                        .alloc => .alloc,
                        .free => .free,
                        .free_owned => .free_owned,
                        .open => .open,
                        .close => .close,
                    };
                    const target_expr: ?u32 = switch (kind) {
                        .free, .close => first_arg orelse base_node,
                        .free_owned => base_node,
                        else => null,
                    };
                    return .{ .kind = kind, .target_expr = target_expr, .call_node = call_ast_node };
                }
            }

            // Priority 2: Built-in heuristics (allocator methods)
            if (allocator_utils.isAllocatorExpr(tree, self.type_context, base_node)) {
                if (std.mem.eql(u8, field_name, "alloc") or
                    std.mem.eql(u8, field_name, "dupe") or
                    std.mem.eql(u8, field_name, "create"))
                {
                    return .{ .kind = .alloc, .target_expr = null, .call_node = call_ast_node };
                }
                if (std.mem.eql(u8, field_name, "free") or std.mem.eql(u8, field_name, "destroy")) {
                    return .{ .kind = .free, .target_expr = first_arg, .call_node = call_ast_node };
                }
            }

            if (std.mem.eql(u8, field_name, "allocPrint")) {
                if (first_arg) |arg_node| {
                    if (allocator_utils.isAllocatorExpr(tree, self.type_context, arg_node)) {
                        return .{ .kind = .alloc, .target_expr = null, .call_node = call_ast_node };
                    }
                }
            }

            // Priority 3: Type-based open detection with strict type info.
            const type_status = classifyResourceReturningCall(self, call_ast_node);
            if (type_status == .resource) {
                return .{ .kind = .open, .target_expr = null, .call_node = call_ast_node };
            }

            // Priority 4: Name-based open detection with known base types (only when type info is missing).
            if (type_status == .unknown) {
                if ((std.mem.eql(u8, field_name, "open") or
                    std.mem.eql(u8, field_name, "openFile") or
                    std.mem.eql(u8, field_name, "openDir") or
                    std.mem.eql(u8, field_name, "openIterableDir") or
                    std.mem.eql(u8, field_name, "createFile")) and
                    isKnownOpenBase(self, tree, base_node))
                {
                    return .{ .kind = .open, .target_expr = null, .call_node = call_ast_node };
                }
            }

            if (std.mem.eql(u8, field_name, "close")) {
                const target_expr = first_arg orelse base_node;
                return .{ .kind = .close, .target_expr = target_expr, .call_node = call_ast_node };
            }
            return null;
        }

        const ResourceReturnStatus = enum {
            unknown,
            resource,
            non_resource,
        };

        /// Classify whether a call returns a known resource type.
        /// Uses strict type information and avoids name-only heuristics.
        pub fn classifyResourceReturningCall(self: *_Engine, call_ast_node: u32) ResourceReturnStatus {
            const type_ctx = self.type_context orelse return .unknown;
            if (type_ctx.getExpressionTypeStrict(call_ast_node)) |strict_info| {
                if (strict_info.type_str) |type_str| {
                    if (std.mem.eql(u8, type_str, "std.fs.File") or
                        std.mem.eql(u8, type_str, "std.posix.fd_t") or
                        std.mem.eql(u8, type_str, "std.fs.Dir") or
                        std.mem.eql(u8, type_str, "std.fs.IterableDir"))
                    {
                        return .resource;
                    }
                    return .non_resource;
                }

                return switch (strict_info.kind) {
                    .int,
                    .uint,
                    .float,
                    .bool_type,
                    .void_type,
                    .error_union,
                    => .non_resource,
                    else => .unknown,
                };
            }

            if (type_ctx.getExpressionType(call_ast_node)) |loose_info| {
                if (loose_info.type_str) |type_str| {
                    if (std.mem.eql(u8, type_str, "std.fs.File") or
                        std.mem.eql(u8, type_str, "std.posix.fd_t") or
                        std.mem.eql(u8, type_str, "std.fs.Dir") or
                        std.mem.eql(u8, type_str, "std.fs.IterableDir"))
                    {
                        return .resource;
                    }
                }
            }

            return .unknown;
        }

        pub fn isKnownOpenBase(self: *_Engine, tree: *const std.zig.Ast, base_node: u32) bool {
            _ = self;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);
            const token_tags = tree.tokens.items(.tag);
            const main_tokens = tree.nodes.items(.main_token);

            if (base_node >= tags.len) return false;
            switch (tags[base_node]) {
                .identifier => {
                    const base_token = main_tokens[base_node];
                    if (base_token >= token_tags.len or token_tags[base_token] != .identifier) return false;
                    const base_name = tree.tokenSlice(base_token);
                    return std.mem.eql(u8, base_name, "posix");
                },
                .field_access => {
                    const field_access_data = datas[base_node].node_and_token;
                    const base_expr = @intFromEnum(field_access_data[0]);
                    const field_token = field_access_data[1];
                    if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return false;
                    const field_name = tree.tokenSlice(field_token);
                    if (!std.mem.eql(u8, field_name, "posix") and !std.mem.eql(u8, field_name, "fs")) return false;
                    if (base_expr >= tags.len or tags[base_expr] != .identifier) return false;
                    const base_token = main_tokens[base_expr];
                    if (base_token >= token_tags.len or token_tags[base_token] != .identifier) return false;
                    const base_name = tree.tokenSlice(base_token);
                    return std.mem.eql(u8, base_name, "std");
                },
                else => return false,
            }
        }

        pub fn isDefinitelyNonAllocExpr(self: *_Engine, tree: *const std.zig.Ast, expr_node: u32) bool {
            if (resolveResourceCallFromExpr(self, tree, expr_node)) |call_info| {
                return call_info.kind != .alloc and call_info.kind != .open;
            }

            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);

            if (expr_node >= tags.len) return false;
            return switch (tags[expr_node]) {
                .slice,
                .slice_open,
                .slice_sentinel,
                .address_of,
                .array_mult,
                .array_cat,
                .array_init,
                .array_init_comma,
                .array_init_one,
                .array_init_one_comma,
                .array_init_dot,
                .array_init_dot_comma,
                .array_init_dot_two,
                .array_init_dot_two_comma,
                .struct_init,
                .struct_init_comma,
                .struct_init_one,
                .struct_init_one_comma,
                .struct_init_dot,
                .struct_init_dot_comma,
                .struct_init_dot_two,
                .struct_init_dot_two_comma,
                => true,
                .grouped_expression, .unwrap_optional => blk: {
                    const data = datas[expr_node].node_and_token;
                    break :blk isDefinitelyNonAllocExpr(self, tree, @intFromEnum(data[0]));
                },
                .@"try" => isDefinitelyNonAllocExpr(self, tree, @intFromEnum(datas[expr_node].node)),
                .@"catch" => blk: {
                    const pair = datas[expr_node].node_and_node;
                    const left = isDefinitelyNonAllocExpr(self, tree, @intFromEnum(pair[0]));
                    const right = isDefinitelyNonAllocExpr(self, tree, @intFromEnum(pair[1]));
                    break :blk left and right;
                },
                else => false,
            };
        }
    };
}
