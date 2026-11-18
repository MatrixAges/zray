const std = @import("std");
const columns = @import("zx").columns;
const Function = @import("../function.zig");
const Summaries = @import("../summaries.zig");
const checking = @import("generated_uniqueness_function_reads");

pub fn unchanged(summaries: *const Summaries, reads: []const Function.Read) bool {
    const Parameter = @typeInfo(@TypeOf(checking.executeValue)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;
    const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
    const Table = std.meta.Child(@FieldType(Input, "tables"));
    const table_info = @typeInfo(Function.Table).@"enum";
    var tables: [table_info.field_names.len]Table = undefined;

    inline for (table_info.field_names, table_info.field_values) |name, value| {
        tables[value] = @ptrCast(&@field(summaries, name));
    }

    const input: Input = .{
        .reads = columns.storage.view(@FieldType(Input, "reads"), reads),
        .tables = &tables,
    };

    var memory = std.heap.FixedBufferAllocator.init(&.{});

    return checking.executeValue(memory.allocator(), if (indirect) &input else input) catch |err| {
        std.debug.panic("read validation failed: {s}", .{@errorName(err)});
    };
}
