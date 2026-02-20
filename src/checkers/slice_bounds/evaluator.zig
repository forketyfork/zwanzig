const std = @import("std");
const AbstractValue = @import("../../engine/value.zig").AbstractValue;
const ProgramState = @import("../../engine/state.zig").ProgramState;
const ids = @import("../../ids.zig");
const Cfg = @import("../../cfg.zig").Cfg;
const AnalysisEngine = @import("../../engine.zig").AnalysisEngine;

pub const BoundsRisk = enum {
    safe,
    definitely_oob,
    possibly_oob,
    unknown,
};

pub const BoundsSite = struct {
    ast_node: u32,
    array_or_slice_node: u32,
    index_node: u32,
};

pub fn assessBoundsRiskWithState(
    tree: *const std.zig.Ast,
    site: BoundsSite,
    state: *const ProgramState,
    engine: *AnalysisEngine,
    cfg: *const Cfg,
) BoundsRisk {
    _ = engine;
    _ = cfg;

    const index_value = evaluateExpr(tree, site.index_node, state);
    const length_value = evaluateLength(tree, site.array_or_slice_node, state);

    return compareBounds(index_value, length_value);
}

pub fn assessBoundsRiskWithoutState(tree: *const std.zig.Ast, site: BoundsSite) BoundsRisk {
    const index_value = evaluateExprWithoutState(tree, site.index_node);
    const length_value = evaluateLengthWithoutState(tree, site.array_or_slice_node);

    return compareBounds(index_value, length_value);
}

fn compareBounds(index_value: AbstractValue, length_value: AbstractValue) BoundsRisk {
    // If index is a concrete value and length is a concrete value, we can check precisely
    if (index_value == .concrete_int and length_value == .concrete_int) {
        if (index_value.concrete_int < 0 or index_value.concrete_int >= length_value.concrete_int) {
            return .definitely_oob;
        }
        return .safe;
    }

    // If index is a range and length is concrete, check if any value in range is OOB
    if (index_value == .int_range and length_value == .concrete_int) {
        const range = index_value.int_range;
        const len = length_value.concrete_int;

        // If minimum index is negative or maximum index is >= length, definitely OOB
        if (range.min < 0 or range.min >= len) {
            return .definitely_oob;
        }
        if (range.max >= len) {
            return .possibly_oob;
        }
        return .safe;
    }

    // If index is concrete and length is a range, check conservatively
    if (index_value == .concrete_int and length_value == .int_range) {
        const idx = index_value.concrete_int;
        const range = length_value.int_range;

        if (idx < 0) {
            return .definitely_oob;
        }
        // If index is greater than or equal to max possible length, definitely OOB
        if (idx >= range.max) {
            return .definitely_oob;
        }
        // If index might be >= min length, possibly OOB
        if (idx >= range.min) {
            return .possibly_oob;
        }
        return .safe;
    }

    // If both are ranges, check for potential overlap
    if (index_value == .int_range and length_value == .int_range) {
        const idx_range = index_value.int_range;
        const len_range = length_value.int_range;

        // If minimum index is negative, definitely OOB
        if (idx_range.min < 0) {
            return .definitely_oob;
        }
        // If minimum index >= maximum possible length, definitely OOB
        if (idx_range.min >= len_range.max) {
            return .definitely_oob;
        }
        // If maximum index >= minimum possible length, possibly OOB
        if (idx_range.max >= len_range.min) {
            return .possibly_oob;
        }
        return .safe;
    }

    // If we can't determine, return unknown
    return .unknown;
}

fn evaluateExpr(tree: *const std.zig.Ast, node: u32, state: *const ProgramState) AbstractValue {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    if (node >= tags.len) return .unknown;

    switch (tags[node]) {
        .number_literal => {
            const token = tree.nodes.items(.main_token)[node];
            const slice = tree.tokenSlice(token);
            if (std.fmt.parseInt(i64, slice, 0)) |value| {
                return .{ .concrete_int = value };
            } else |_| {
                return .unknown;
            }
        },
        .identifier => {
            const token = tree.nodes.items(.main_token)[node];
            const var_id = ids.varId(token);
            return state.getVar(var_id) orelse .unknown;
        },
        .add, .sub => {
            const pair = datas[node].node_and_node;
            const lhs = evaluateExpr(tree, @intFromEnum(pair[0]), state);
            const rhs = evaluateExpr(tree, @intFromEnum(pair[1]), state);
            return evalBinaryOp(tags[node], lhs, rhs);
        },
        else => return .unknown,
    }
}

fn evaluateExprWithoutState(tree: *const std.zig.Ast, node: u32) AbstractValue {
    const tags = tree.nodes.items(.tag);

    if (node >= tags.len) return .unknown;

    switch (tags[node]) {
        .number_literal => {
            const token = tree.nodes.items(.main_token)[node];
            const slice = tree.tokenSlice(token);
            if (std.fmt.parseInt(i64, slice, 0)) |value| {
                return .{ .concrete_int = value };
            } else |_| {
                return .unknown;
            }
        },
        else => return .unknown,
    }
}

fn evaluateLength(tree: *const std.zig.Ast, node: u32, state: *const ProgramState) AbstractValue {
    _ = state;
    return evaluateLengthWithoutState(tree, node);
}

fn evaluateLengthWithoutState(tree: *const std.zig.Ast, node: u32) AbstractValue {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    if (node >= tags.len) return .unknown;

    // Try to determine if this is an array with a known length
    switch (tags[node]) {
        .array_init_one, .array_init_one_comma => {
            const elements = datas[node].opt_node_and_opt_node;
            var count: i64 = 0;
            if (elements[0].unwrap()) |_| count += 1;
            if (elements[1].unwrap()) |_| count += 1;
            return .{ .concrete_int = count };
        },
        .array_init, .array_init_comma => {
            const extra = datas[node].extra_range;
            const start = @intFromEnum(extra.start);
            const end = @intFromEnum(extra.end);
            const count: i64 = @intCast(end - start);
            return .{ .concrete_int = count };
        },
        .array_init_dot_two, .array_init_dot_two_comma => {
            const elements = datas[node].opt_node_and_opt_node;
            var count: i64 = 0;
            if (elements[0].unwrap()) |_| count += 1;
            if (elements[1].unwrap()) |_| count += 1;
            return .{ .concrete_int = count };
        },
        .array_init_dot, .array_init_dot_comma => {
            const extra = datas[node].extra_range;
            const start = @intFromEnum(extra.start);
            const end = @intFromEnum(extra.end);
            const count: i64 = @intCast(end - start);
            return .{ .concrete_int = count };
        },
        .string_literal => {
            const token = tree.nodes.items(.main_token)[node];
            const slice = tree.tokenSlice(token);
            // String literal length (excluding quotes)
            if (slice.len >= 2) {
                const len: i64 = @intCast(slice.len - 2);
                return .{ .concrete_int = len };
            }
            return .unknown;
        },
        else => return .unknown,
    }
}

fn evalBinaryOp(op: std.zig.Ast.Node.Tag, lhs: AbstractValue, rhs: AbstractValue) AbstractValue {
    if (lhs == .concrete_int and rhs == .concrete_int) {
        const result = switch (op) {
            .add => lhs.concrete_int + rhs.concrete_int,
            .sub => lhs.concrete_int - rhs.concrete_int,
            else => return .unknown,
        };
        return .{ .concrete_int = result };
    }

    if (lhs == .int_range and rhs == .concrete_int) {
        const range = lhs.int_range;
        const value = rhs.concrete_int;
        return switch (op) {
            .add => .{ .int_range = .{
                .min = range.min + value,
                .max = range.max + value,
            } },
            .sub => .{ .int_range = .{
                .min = range.min - value,
                .max = range.max - value,
            } },
            else => .unknown,
        };
    }

    if (lhs == .concrete_int and rhs == .int_range) {
        const value = lhs.concrete_int;
        const range = rhs.int_range;
        return switch (op) {
            .add => .{ .int_range = .{
                .min = value + range.min,
                .max = value + range.max,
            } },
            .sub => .{ .int_range = .{
                .min = value - range.max,
                .max = value - range.min,
            } },
            else => .unknown,
        };
    }

    if (lhs == .int_range and rhs == .int_range) {
        const lhs_range = lhs.int_range;
        const rhs_range = rhs.int_range;
        return switch (op) {
            .add => .{ .int_range = .{
                .min = lhs_range.min + rhs_range.min,
                .max = lhs_range.max + rhs_range.max,
            } },
            .sub => .{ .int_range = .{
                .min = lhs_range.min - rhs_range.max,
                .max = lhs_range.max - rhs_range.min,
            } },
            else => .unknown,
        };
    }

    return .unknown;
}
