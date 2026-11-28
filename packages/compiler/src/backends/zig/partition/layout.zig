pub const available = @import("parser_options").generated_parser;
const entry = if (available) @import("generated_partition_layout") else void;

pub const FunctionFiles = struct {
    paths: []const []const u8,
    names: []const []const u8,
    sizes: []const u64,
};

pub const Plan = if (available)
    @typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload

else
    void;
