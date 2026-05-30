const defaults = struct {
    const timeout_ms = 1000;
};

const internal_limit = 10;

pub const DefaultTimeoutMs = defaults.timeout_ms;

pub const DefaultLimit = internal_limit;

pub const ExportedType = defaults.ExportedType;
