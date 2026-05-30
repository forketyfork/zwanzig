const inner = @import("alias_inner.zig");

pub const ImportedModule = @import("alias_inner.zig");
pub const ExportedType = inner.Exported;
pub const SameModuleAlias = ExportedType;
pub const RegularType = struct {};

pub fn unusedFunction() void {}
