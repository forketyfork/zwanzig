const std = @import("std");

const Layout = enum { interleaved, sequential };
const RopeOpts = struct {
    layout: Layout = .sequential,
    factor: f32 = 1.0,
};

const Tensor = struct {
    id: u32,
    fn init(id: u32) Tensor {
        return .{ .id = id };
    }
    fn splitAxis(self: Tensor, _: anytype, _: anytype) Tensor { return self; }
    fn merge(self: Tensor, _: anytype) Tensor { return self; }
    fn squeeze(self: Tensor, _: anytype) Tensor { return self; }
    fn add(self: Tensor, _: Tensor) Tensor { return self; }
    fn mul(self: Tensor, _: Tensor) Tensor { return self; }
    fn convert(self: Tensor, _: anytype) Tensor { return self; }
    fn dot(self: Tensor, _: Tensor, _: anytype) Tensor { return self; }
    fn reshape(self: Tensor, _: anytype) Tensor { return self; }
    fn transpose(self: Tensor, _: anytype) Tensor { return self; }
    fn broadcast(self: Tensor, _: anytype, _: anytype) Tensor { return self; }
    fn addConstant(self: Tensor, _: f32) Tensor { return self; }
    fn powByConst(self: Tensor, _: u32) Tensor { return self; }
    fn sum(self: Tensor, _: anytype) Tensor { return self; }
    fn eq(self: Tensor, _: Tensor) Tensor { return self; }
    fn select(self: Tensor, _: Tensor, _: Tensor) Tensor { return self; }
};

const res = 0;

const SplitPair = struct { real: Tensor, imag: Tensor };

fn splitRealImg(x: Tensor, layout: Layout) SplitPair {
    _ = layout;
    return .{ .real = x, .imag = x };
}

fn mergeRealImg(a: Tensor, b: Tensor, layout: Layout) Tensor {
    _ = b;
    _ = layout;
    return a;
}

fn rope(x: Tensor, opts: RopeOpts) Tensor {
    _ = opts;
    return x;
}

pub const Activation = union(enum) {
    relu,
    leaky: f32,
    gelu,
    pub fn forward(self: Activation, x: Tensor) Tensor {
        return switch (self) {
            .relu => x,
            .gelu => x,
            .leaky => x,
        };
    }
};

pub fn chainModules(module_list: anytype, input: Tensor) Tensor {
    const T = @TypeOf(module_list);
    switch (@typeInfo(T)) {
        .Struct => |info| {
            var x = input;
            inline for (info.fields) |field| {
                x = @field(module_list, field.name).forward(x);
            }
            return x;
        },
        else => @compileError("chainModules expects struct"),
    }
}

pub const JsonOpts = struct {
    factor: f32 = 1.0,
};

pub fn jsonParse(allocator: std.mem.Allocator, source: anytype) !JsonOpts {
    const parsed = try std.json.Value.jsonParse(allocator, source, .{});
    if (parsed != .object) return error.Invalid;
    if (parsed.object.get("factor")) |val| {
        _ = val;
    }
    return .{};
}

const Helper = struct {
    fn scale(x: Tensor, f: f32) Tensor {
        _ = f;
        return x;
    }
    fn chain(a: Tensor, b: Tensor, c: Tensor) Tensor {
        return a.add(b).mul(c);
    }
};

fn helper0(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper1(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper2(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper3(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper4(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper5(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper6(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper7(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper8(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper9(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper10(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper11(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper12(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper13(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper14(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper15(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper16(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper17(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper18(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper19(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper20(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper21(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper22(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper23(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper24(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper25(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper26(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper27(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper28(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper29(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper30(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper31(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper32(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper33(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper34(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper35(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper36(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper37(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper38(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper39(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper40(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper41(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper42(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper43(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper44(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper45(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper46(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper47(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper48(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper49(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper50(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper51(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper52(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper53(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper54(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper55(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper56(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper57(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper58(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper59(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper60(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper61(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper62(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper63(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper64(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper65(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper66(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper67(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper68(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper69(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper70(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper71(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper72(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper73(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper74(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper75(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper76(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper77(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper78(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper79(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper80(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper81(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper82(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper83(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper84(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper85(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper86(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper87(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper88(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper89(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper90(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper91(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper92(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper93(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper94(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper95(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper96(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper97(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper98(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper99(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper100(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper101(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper102(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper103(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper104(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper105(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper106(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper107(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper108(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper109(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper110(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper111(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper112(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper113(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper114(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper115(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper116(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper117(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper118(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper119(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper120(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper121(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper122(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper123(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper124(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper125(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper126(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper127(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper128(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper129(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper130(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper131(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper132(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper133(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper134(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper135(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper136(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper137(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper138(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper139(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper140(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper141(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper142(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper143(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper144(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper145(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper146(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper147(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper148(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper149(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper150(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper151(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper152(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper153(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper154(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper155(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper156(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper157(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper158(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper159(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper160(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper161(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper162(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper163(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper164(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper165(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper166(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper167(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper168(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper169(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper170(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper171(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper172(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper173(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper174(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper175(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper176(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper177(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper178(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper179(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper180(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper181(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper182(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper183(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper184(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper185(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper186(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper187(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper188(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper189(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper190(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper191(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper192(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper193(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper194(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper195(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper196(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper197(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper198(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

fn helper199(x: Tensor, opts: RopeOpts) Tensor {
    var input = x;
    {
        const pair = splitRealImg(input, .sequential);
        input = mergeRealImg(pair.real, pair.imag, opts.layout);
    }
    var res_local = Helper.chain(input, input, input);
    res_local = res_local.addConstant(@floatFromInt(@as(u32, res_local.id + 1)));
    return res_local;
}

test "case 0" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(0), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 1" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(1), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 2" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(2), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 3" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(3), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 4" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(4), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 5" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(5), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 6" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(6), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 7" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(7), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 8" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(8), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 9" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(9), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 10" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(10), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 11" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(11), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 12" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(12), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 13" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(13), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 14" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(14), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 15" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(15), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 16" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(16), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 17" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(17), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 18" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(18), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 19" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(19), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 20" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(20), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 21" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(21), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 22" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(22), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 23" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(23), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 24" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(24), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 25" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(25), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 26" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(26), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 27" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(27), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 28" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(28), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 29" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(29), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 30" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(30), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 31" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(31), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 32" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(32), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 33" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(33), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 34" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(34), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 35" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(35), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 36" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(36), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 37" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(37), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 38" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(38), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 39" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(39), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 40" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(40), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 41" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(41), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 42" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(42), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 43" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(43), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 44" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(44), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 45" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(45), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 46" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(46), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 47" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(47), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 48" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(48), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 49" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(49), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 50" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(50), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 51" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(51), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 52" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(52), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 53" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(53), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 54" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(54), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 55" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(55), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 56" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(56), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 57" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(57), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 58" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(58), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 59" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(59), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 60" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(60), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 61" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(61), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 62" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(62), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 63" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(63), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 64" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(64), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 65" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(65), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 66" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(66), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 67" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(67), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 68" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(68), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 69" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(69), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 70" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(70), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 71" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(71), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 72" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(72), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 73" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(73), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 74" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(74), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 75" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(75), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 76" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(76), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 77" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(77), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 78" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(78), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 79" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(79), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 80" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(80), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 81" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(81), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 82" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(82), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 83" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(83), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 84" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(84), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 85" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(85), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 86" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(86), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 87" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(87), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 88" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(88), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 89" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(89), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 90" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(90), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 91" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(91), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 92" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(92), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 93" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(93), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 94" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(94), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 95" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(95), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 96" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(96), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 97" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(97), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 98" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(98), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 99" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(99), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 100" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(100), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 101" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(101), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 102" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(102), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 103" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(103), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 104" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(104), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 105" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(105), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 106" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(106), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 107" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(107), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 108" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(108), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 109" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(109), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 110" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(110), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 111" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(111), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 112" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(112), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 113" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(113), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 114" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(114), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 115" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(115), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 116" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(116), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 117" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(117), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 118" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(118), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

test "case 119" {
    const Local = struct {
        fn _fwd(x: Tensor, opts: RopeOpts) Tensor {
            var input = x;
            {
                const pair = splitRealImg(input, .sequential);
                input = mergeRealImg(pair.real, pair.imag, opts.layout);
            }
            var res_local = rope(input, opts).squeeze(0);
            {
                const pair = splitRealImg(res_local, opts.layout);
                res_local = mergeRealImg(pair.real, pair.imag, .sequential);
            }
            return res_local;
        }
    };
    const out_val = Local._fwd(Tensor.init(119), .{ .layout = .sequential, .factor = 1.0 });
    _ = out_val;
}

// EXPECT: none