const std = @import("std");

pub const EngineError = std.mem.Allocator.Error || error{AnalysisLimitExceeded};

/// Default maximum inlining depth for interprocedural analysis.
/// Functions are inlined up to this depth; deeper calls are treated as unknown effects.
pub const DEFAULT_MAX_INLINE_DEPTH: u32 = 3;
pub const DEFAULT_MAX_WORKLIST_STEPS: usize = 200_000;
