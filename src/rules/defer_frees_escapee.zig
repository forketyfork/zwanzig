const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;
const ast_walk = @import("../ast_walk.zig");
const call_utils = @import("../analysis/call_utils.zig");

const Ast = std.zig.Ast;

/// Detects a `defer` whose release call frees a local resource that has
/// already escaped into a container declared in a strictly outer scope.
///
/// When the inner block ends, the deferred free fires unconditionally while
/// the outer container still holds a reference to the freed memory. The next
/// access through the container is a use-after-free.
///
/// Buggy pattern:
/// ```zig
/// if (indent > 0) {
///     const spaces = try allocator.alloc(u8, indent);
///     defer allocator.free(spaces); // fires when this if-block exits
///     try run_inputs.append(allocator, .{ .text = spaces });
/// }
/// // run_inputs.items now holds a dangling slice
/// ```
///
/// The rule is intentionally heuristic: it focuses on the common shape where
/// `defer <receiver>.free(X)` (or `destroy`) appears in a nested block
/// alongside an `append`/`appendSlice`/`appendAssumeCapacity`/
/// `appendSliceAssumeCapacity`/`insert`/`insertSlice` call whose receiver is
/// not declared in the same block and whose arguments mention `X`. It will
/// miss escapes that go through helper functions, but it is precise enough
/// to flag the architect crash that motivated it without firing on the
/// wider `defer X.deinit(allocator)` idiom.
///
/// `put`-family methods (`put`, `putAssumeCapacity`, `putNoClobber`) are
/// excluded on purpose because many non-container APIs (caches, writers, IO
/// sinks) expose the same name but consume their data during the call. Lifting
/// this restriction needs type information and belongs in a future engine-
/// backed extension of `store-violations-engine`.
///
/// `errdefer` is intentionally not covered yet: the standard
/// "errdefer-free-then-try-append" ownership-transfer idiom is correct
/// (errdefer does not fire on the success path), and a sound `errdefer`
/// version of this rule needs to also see whether any error-returning
/// statement runs after the escape, which is left for a follow-up.
pub const DeferFreesEscapeeRule = struct {
    pub const rule: Rule = .{
        .name = "defer-frees-escapee",
        .default_severity = .err,
        .checkFn = check,
    };

    /// Method names strongly associated with ArrayList-style borrowing storage.
    /// `put`-family methods are deliberately excluded: many non-container APIs
    /// (caches, writers, IO sinks) also expose `put` but consume their data
    /// during the call, so a name-based match produces false positives. A
    /// follow-up that consults type info could re-enable HashMap.put.
    const storage_methods = [_][]const u8{
        "append",
        "appendAssumeCapacity",
        "appendSlice",
        "appendSliceAssumeCapacity",
        "insert",
        "insertSlice",
    };

    /// Subset of `storage_methods` whose direct slice argument is iterated
    /// and copied (not retained). We require the freed name to appear nested
    /// inside the slice expression rather than being the whole argument.
    const slice_store_methods = [_][]const u8{
        "appendSlice",
        "appendSliceAssumeCapacity",
        "insertSlice",
    };

    const release_methods = [_][]const u8{ "free", "destroy" };

    const Finding = struct {
        receiver_root: []const u8,
        method: []const u8,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);

        for (tags, 0..) |tag, i| {
            if (tag != .fn_decl) continue;
            const fn_node: u32 = @intCast(i);
            const data = datas[fn_node].node_and_node;
            const body_node = @intFromEnum(data[1]);
            if (body_node == 0 or body_node >= tags.len) continue;

            try checkAllInnerBlocks(
                src,
                allocator,
                diagnostics,
                tree,
                tags,
                datas,
                token_tags,
                main_tokens,
                body_node,
            );
        }
    }

    fn checkAllInnerBlocks(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        main_tokens: []const Ast.TokenIndex,
        fn_body: u32,
    ) RuleError!void {
        const Collector = struct {
            fn_body: u32,
            out: *std.ArrayList(u32),
            allocator: std.mem.Allocator,
            stop: bool = false,

            pub fn visit(self: *@This(), inner_tree: *const Ast, node: u32, tag: Ast.Node.Tag) RuleError!void {
                _ = inner_tree;
                if (!isBlockTag(tag)) return;
                if (node == self.fn_body) return;
                try self.out.append(self.allocator, node);
            }
        };

        var inner_blocks: std.ArrayList(u32) = .empty;
        defer inner_blocks.deinit(allocator);

        var collector = Collector{
            .fn_body = fn_body,
            .out = &inner_blocks,
            .allocator = allocator,
        };
        try walkSkippingNestedFns(Collector, tree, fn_body, &collector);

        for (inner_blocks.items) |block_node| {
            try checkBlock(
                src,
                allocator,
                diagnostics,
                tree,
                tags,
                datas,
                token_tags,
                main_tokens,
                block_node,
            );
        }
    }

    fn checkBlock(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        main_tokens: []const Ast.TokenIndex,
        block_node: u32,
    ) RuleError!void {
        var scratch_buf: [2]u32 = undefined;
        const stmts = blockStatements(tree, tags, datas, block_node, &scratch_buf);
        if (stmts.len == 0) return;

        var local_names: std.ArrayList([]const u8) = .empty;
        defer local_names.deinit(allocator);
        try collectLocalNames(allocator, tree, tags, datas, token_tags, block_node, &local_names);

        for (stmts) |stmt| {
            if (stmt >= tags.len) continue;
            const stag = tags[stmt];
            if (stag != .@"defer") continue;

            const body = deferBody(stag, datas, stmt) orelse continue;
            const freed_name = extractFreedName(tree, tags, datas, main_tokens, token_tags, body) orelse continue;
            if (!nameMatches(local_names.items, freed_name)) continue;

            const maybe_finding = try findEscapeCall(
                tree,
                tags,
                datas,
                main_tokens,
                token_tags,
                block_node,
                stmt,
                freed_name,
                local_names.items,
            );
            const finding = maybe_finding orelse continue;

            const loc = try src.tokenLocation(main_tokens[stmt]);
            const message = try std.fmt.allocPrint(
                allocator,
                "'{s}' is freed by this defer when the block exits, but escaped into '{s}' via .{s}() — use-after-free",
                .{ freed_name, finding.receiver_root, finding.method },
            );
            defer allocator.free(message);

            const diag = try Diagnostic.initAtLocation(
                allocator,
                src.getFilePath(),
                rule.name,
                rule.default_severity,
                message,
                loc.line,
                loc.column,
            );
            try diagnostics.append(allocator, diag);
        }
    }

    fn isBlockTag(tag: Ast.Node.Tag) bool {
        return switch (tag) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => true,
            else => false,
        };
    }

    fn blockStatements(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        block_node: u32,
        scratch: *[2]u32,
    ) []const u32 {
        if (block_node >= tags.len) return &.{};
        switch (tags[block_node]) {
            .block, .block_semicolon => {
                const range = datas[block_node].extra_range;
                const start = @intFromEnum(range.start);
                const end = @intFromEnum(range.end);
                return tree.extra_data[start..end];
            },
            .block_two, .block_two_semicolon => {
                const pair = datas[block_node].opt_node_and_opt_node;
                var count: usize = 0;
                if (pair[0].unwrap()) |n| {
                    scratch[count] = @intFromEnum(n);
                    count += 1;
                }
                if (pair[1].unwrap()) |n| {
                    scratch[count] = @intFromEnum(n);
                    count += 1;
                }
                return scratch[0..count];
            },
            else => return &.{},
        }
    }

    fn deferBody(stmt_tag: Ast.Node.Tag, datas: []const Ast.Node.Data, stmt_node: u32) ?u32 {
        return switch (stmt_tag) {
            .@"defer" => @intFromEnum(datas[stmt_node].node),
            else => null,
        };
    }

    /// Recognise `<receiver>.free(X)` and `<receiver>.destroy(X)` and return
    /// the identifier name of X. Returns null otherwise.
    fn extractFreedName(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        main_tokens: []const Ast.TokenIndex,
        token_tags: []const std.zig.Token.Tag,
        body_node: u32,
    ) ?[]const u8 {
        if (body_node >= tags.len) return null;
        const tag = tags[body_node];
        if (!call_utils.isCallNode(tag)) return null;

        var buf: [1]Ast.Node.Index = undefined;
        const full = tree.fullCall(&buf, @enumFromInt(body_node)) orelse return null;
        if (full.ast.params.len != 1) return null;

        const fn_expr = @intFromEnum(full.ast.fn_expr);
        if (fn_expr >= tags.len or tags[fn_expr] != .field_access) return null;
        const field_token = datas[fn_expr].node_and_token[1];
        if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return null;
        const method_name = tree.tokenSlice(field_token);
        if (!nameIn(&release_methods, method_name)) return null;

        const arg = @intFromEnum(full.ast.params[0]);
        if (arg >= tags.len or tags[arg] != .identifier) return null;
        const arg_token = main_tokens[arg];
        if (arg_token >= token_tags.len or token_tags[arg_token] != .identifier) return null;
        return tree.tokenSlice(arg_token);
    }

    /// Collect names declared as direct statements of `block_node`. We
    /// deliberately skip nested blocks: a var declared inside an inner block
    /// shadows nothing in `block_node`'s scope, and treating it as local
    /// would suppress diagnostics for references to outer variables of the
    /// same name.
    fn collectLocalNames(
        allocator: std.mem.Allocator,
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        block_node: u32,
        out: *std.ArrayList([]const u8),
    ) RuleError!void {
        var scratch_buf: [2]u32 = undefined;
        const stmts = blockStatements(tree, tags, datas, block_node, &scratch_buf);
        for (stmts) |stmt| {
            if (stmt >= tags.len) continue;
            const tag = tags[stmt];
            if (tag != .local_var_decl and tag != .simple_var_decl and tag != .aligned_var_decl) continue;
            const full = tree.fullVarDecl(@enumFromInt(stmt)) orelse continue;
            const name_token = full.ast.mut_token + 1;
            if (name_token >= token_tags.len) continue;
            if (token_tags[name_token] != .identifier) continue;
            try out.append(allocator, tree.tokenSlice(name_token));
        }
    }

    fn walkSkippingNestedFns(
        comptime Visitor: type,
        tree: *const Ast,
        node: u32,
        visitor: *Visitor,
    ) RuleError!void {
        if (node == 0) return;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return;
        if (@hasField(Visitor, "stop") and visitor.stop) return;

        const tag = tags[node];
        if (tag == .fn_decl or tag == .test_decl) return;

        try visitor.visit(tree, node, tag);
        if (@hasField(Visitor, "stop") and visitor.stop) return;

        const Adapter = struct {
            fn visitChild(inner_tree: *const Ast, child_node: u32, inner_visitor: *Visitor) RuleError!void {
                return walkSkippingNestedFns(Visitor, inner_tree, child_node, inner_visitor);
            }
        };

        try ast_walk.walkChildren(Visitor, tree, node, visitor, Adapter.visitChild);
    }

    fn findEscapeCall(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        main_tokens: []const Ast.TokenIndex,
        token_tags: []const std.zig.Token.Tag,
        block_node: u32,
        skip_node: u32,
        freed_name: []const u8,
        local_names: []const []const u8,
    ) RuleError!?Finding {
        const Finder = struct {
            tree: *const Ast,
            tags: []const Ast.Node.Tag,
            datas: []const Ast.Node.Data,
            main_tokens: []const Ast.TokenIndex,
            token_tags: []const std.zig.Token.Tag,
            freed_name: []const u8,
            local_names: []const []const u8,
            skip_node: u32,
            result: ?Finding = null,
            stop: bool = false,

            pub fn visit(self: *@This(), inner_tree: *const Ast, node: u32, tag: Ast.Node.Tag) RuleError!void {
                _ = inner_tree;
                if (node == self.skip_node) return;
                if (!call_utils.isCallNode(tag)) return;

                var buf: [1]Ast.Node.Index = undefined;
                const full = self.tree.fullCall(&buf, @enumFromInt(node)) orelse return;

                const fn_expr = @intFromEnum(full.ast.fn_expr);
                if (fn_expr >= self.tags.len) return;
                if (self.tags[fn_expr] != .field_access) return;

                const fa = self.datas[fn_expr].node_and_token;
                const method_token = fa[1];
                if (method_token >= self.token_tags.len) return;
                if (self.token_tags[method_token] != .identifier) return;
                const method_name = self.tree.tokenSlice(method_token);
                if (!nameIn(&storage_methods, method_name)) return;

                const receiver_root = rootIdentifierName(
                    self.tree,
                    self.tags,
                    self.datas,
                    self.main_tokens,
                    self.token_tags,
                    @intFromEnum(fa[0]),
                ) orelse return;
                if (nameMatches(self.local_names, receiver_root)) return;
                if (std.mem.eql(u8, receiver_root, self.freed_name)) return;

                const method_is_slice_store = nameIn(&slice_store_methods, method_name);

                for (full.ast.params) |param| {
                    const param_idx = @intFromEnum(param);
                    // For *Slice methods the slice argument itself is iterated
                    // and copied element-by-element, so a bare `appendSlice(out, X)`
                    // does not retain `X`. Only flag *Slice methods when `X`
                    // appears nested inside a struct/array literal element.
                    if (method_is_slice_store and identifierMatches(
                        self.tree,
                        self.tags,
                        self.main_tokens,
                        self.token_tags,
                        param_idx,
                        self.freed_name,
                    )) continue;

                    if (try exprMentionsIdentifier(
                        self.tree,
                        self.main_tokens,
                        self.token_tags,
                        param_idx,
                        self.freed_name,
                    )) {
                        self.result = .{
                            .receiver_root = receiver_root,
                            .method = method_name,
                        };
                        self.stop = true;
                        return;
                    }
                }
            }
        };

        var finder = Finder{
            .tree = tree,
            .tags = tags,
            .datas = datas,
            .main_tokens = main_tokens,
            .token_tags = token_tags,
            .freed_name = freed_name,
            .local_names = local_names,
            .skip_node = skip_node,
        };

        try walkSkippingNestedFns(Finder, tree, block_node, &finder);
        return finder.result;
    }

    fn rootIdentifierName(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        main_tokens: []const Ast.TokenIndex,
        token_tags: []const std.zig.Token.Tag,
        node: u32,
    ) ?[]const u8 {
        var current = node;
        while (true) {
            if (current >= tags.len) return null;
            switch (tags[current]) {
                .identifier => {
                    const token = main_tokens[current];
                    if (token >= token_tags.len) return null;
                    if (token_tags[token] != .identifier) return null;
                    return tree.tokenSlice(token);
                },
                .field_access => {
                    current = @intFromEnum(datas[current].node_and_token[0]);
                },
                else => return null,
            }
        }
    }

    /// True when `expr_node` is exactly the identifier `target_name` (no
    /// wrapping like field access, struct literal, etc.).
    fn identifierMatches(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        main_tokens: []const Ast.TokenIndex,
        token_tags: []const std.zig.Token.Tag,
        node: u32,
        target_name: []const u8,
    ) bool {
        if (node >= tags.len) return false;
        if (tags[node] != .identifier) return false;
        const token = main_tokens[node];
        if (token >= token_tags.len) return false;
        if (token_tags[token] != .identifier) return false;
        return std.mem.eql(u8, tree.tokenSlice(token), target_name);
    }

    fn exprMentionsIdentifier(
        tree: *const Ast,
        main_tokens: []const Ast.TokenIndex,
        token_tags: []const std.zig.Token.Tag,
        expr_node: u32,
        target_name: []const u8,
    ) RuleError!bool {
        const Finder = struct {
            tree: *const Ast,
            main_tokens: []const Ast.TokenIndex,
            token_tags: []const std.zig.Token.Tag,
            target_name: []const u8,
            found: bool = false,
            stop: bool = false,

            pub fn visit(self: *@This(), inner_tree: *const Ast, node: u32, tag: Ast.Node.Tag) RuleError!void {
                _ = inner_tree;
                if (tag != .identifier) return;
                const token = self.main_tokens[node];
                if (token >= self.token_tags.len) return;
                if (self.token_tags[token] != .identifier) return;
                const name = self.tree.tokenSlice(token);
                if (std.mem.eql(u8, name, self.target_name)) {
                    self.found = true;
                    self.stop = true;
                }
            }
        };

        var finder = Finder{
            .tree = tree,
            .main_tokens = main_tokens,
            .token_tags = token_tags,
            .target_name = target_name,
        };
        try walkSkippingNestedFns(Finder, tree, expr_node, &finder);
        return finder.found;
    }

    fn nameIn(list: []const []const u8, needle: []const u8) bool {
        for (list) |entry| {
            if (std.mem.eql(u8, entry, needle)) return true;
        }
        return false;
    }

    fn nameMatches(list: []const []const u8, needle: []const u8) bool {
        return nameIn(list, needle);
    }
};

test "flags defer free of slice escaped into outer ArrayList" {
    const allocator = std.testing.allocator;
    const source_text =
        \\fn render(allocator: std.mem.Allocator) !void {
        \\    var run_inputs: std.ArrayList(Item) = .empty;
        \\    defer run_inputs.deinit(allocator);
        \\    if (true) {
        \\        const spaces = try allocator.alloc(u8, 2);
        \\        defer allocator.free(spaces);
        \\        try run_inputs.append(allocator, .{ .text = spaces });
        \\    }
        \\}
    ;
    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try DeferFreesEscapeeRule.rule.check(&src, allocator, &diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, diagnostics.items[0].message, 1, "spaces"));
    try std.testing.expect(std.mem.containsAtLeast(u8, diagnostics.items[0].message, 1, "run_inputs"));
}

test "ignores defer at function-body scope" {
    const allocator = std.testing.allocator;
    const source_text =
        \\fn ok(allocator: std.mem.Allocator) !void {
        \\    var run_inputs: std.ArrayList(Item) = .empty;
        \\    defer run_inputs.deinit(allocator);
        \\    const spaces = try allocator.alloc(u8, 2);
        \\    defer allocator.free(spaces);
        \\    try run_inputs.append(allocator, .{ .text = spaces });
        \\}
    ;
    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try DeferFreesEscapeeRule.rule.check(&src, allocator, &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "ignores escape into container declared in the same block" {
    const allocator = std.testing.allocator;
    const source_text =
        \\fn ok(allocator: std.mem.Allocator) !void {
        \\    if (true) {
        \\        var inner: std.ArrayList(Item) = .empty;
        \\        defer inner.deinit(allocator);
        \\        const spaces = try allocator.alloc(u8, 2);
        \\        defer allocator.free(spaces);
        \\        try inner.append(allocator, .{ .text = spaces });
        \\    }
        \\}
    ;
    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try DeferFreesEscapeeRule.rule.check(&src, allocator, &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "ignores defer that frees something never appended" {
    const allocator = std.testing.allocator;
    const source_text =
        \\fn ok(allocator: std.mem.Allocator) !void {
        \\    var run_inputs: std.ArrayList(Item) = .empty;
        \\    defer run_inputs.deinit(allocator);
        \\    if (true) {
        \\        const spaces = try allocator.alloc(u8, 2);
        \\        defer allocator.free(spaces);
        \\        _ = spaces[0];
        \\    }
        \\}
    ;
    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try DeferFreesEscapeeRule.rule.check(&src, allocator, &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "ignores errdefer ownership-transfer idiom" {
    // `errdefer free(x)` followed by `try container.append(x)` is the standard
    // pattern for transferring ownership to the container on success and
    // cleaning up on failure. errdefer does not fire on the success path, so
    // there is no UAF here.
    const allocator = std.testing.allocator;
    const source_text =
        \\fn load(allocator: std.mem.Allocator, src: []const u8, list: *std.ArrayList([]u8)) !void {
        \\    while (true) {
        \\        const path_copy = try allocator.dupe(u8, src);
        \\        errdefer allocator.free(path_copy);
        \\        try list.append(allocator, path_copy);
        \\    }
        \\}
    ;
    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try DeferFreesEscapeeRule.rule.check(&src, allocator, &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "ignores appendSlice that copies elements out of a temporary slice" {
    // `try out.appendSlice(allocator, tmp)` iterates tmp and copies each
    // element into `out`. The slice argument is consumed during the call;
    // freeing tmp afterwards is safe.
    const allocator = std.testing.allocator;
    const source_text =
        \\fn ok(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        \\    if (true) {
        \\        const tmp = try allocator.alloc(u8, 4);
        \\        defer allocator.free(tmp);
        \\        try out.appendSlice(allocator, tmp);
        \\    }
        \\}
    ;
    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try DeferFreesEscapeeRule.rule.check(&src, allocator, &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "flags reference to outer name when an inner block shadows it" {
    // The outer `outer` is the real escape target. The inner block also
    // declares a local named `outer`, but that should not suppress the
    // diagnostic for the append on the outer one.
    const allocator = std.testing.allocator;
    const source_text =
        \\fn render(allocator: std.mem.Allocator) !void {
        \\    var outer: std.ArrayList(Item) = .empty;
        \\    defer outer.deinit(allocator);
        \\    if (true) {
        \\        if (false) {
        \\            var outer: std.ArrayList(Item) = .empty;
        \\            outer.deinit(allocator);
        \\        }
        \\        const spaces = try allocator.alloc(u8, 2);
        \\        defer allocator.free(spaces);
        \\        try outer.append(allocator, .{ .text = spaces });
        \\    }
        \\}
    ;
    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try DeferFreesEscapeeRule.rule.check(&src, allocator, &diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, diagnostics.items[0].message, 1, "outer"));
}

test "flags escape through insertSlice into outer list" {
    const allocator = std.testing.allocator;
    const source_text =
        \\fn render(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) !void {
        \\    if (true) {
        \\        const value = try allocator.alloc(u8, 2);
        \\        defer allocator.free(value);
        \\        try list.insertSlice(allocator, 0, &.{value});
        \\    }
        \\}
    ;
    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try DeferFreesEscapeeRule.rule.check(&src, allocator, &diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}
