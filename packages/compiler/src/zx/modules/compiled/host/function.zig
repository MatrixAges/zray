const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const strings = @import("native.zig").strings;
const columns = @import("../../artifact/materializing/publication/columns.zig");
const Input = std.meta.Child(@FieldType(@import("installation.zig").Layout, "functions"));
const Target = std.meta.Child(@FieldType(Input, "target"));
const Source = std.meta.Child(@FieldType(Input, "source"));

pub const View = struct {
    completed: [1]u64,
    progress: []u64,
    slots: [@typeInfo(ir.FunctionStorage).@"struct".field_names.len]*usize,
    lengths: zx.memory.ColumnLengths,
    tail: columns.Tail(Target),
    target: Target,
    source: Source,
    input: Input,
    pub fn init(self: *View, functions: *ir.FunctionStorage, source: ir.FunctionTable, first: usize, instance: []const u8) void {
        self.completed = .{0};
        self.progress = &self.completed;
        self.slots = zx.memory.borrowColumnLengths(functions);
        self.lengths = &self.slots;

        self.tail.init(functions);

        self.target = .{
            .storage = @ptrCast(&self.tail.storage),
            .shape = null,
        };

        self.source = columns.view(Source, source);

        self.input = .{
            .source = &self.source,
            .target = &self.target,
            .first = first,
            .instance = instance,
            .progress = @ptrCast(&self.progress),
        };
    }
};

pub fn copyExternalDetails(allocator: std.mem.Allocator, source: ir.External) std.mem.Allocator.Error!ir.External {
    var result = source;
    result.errors = if (source.errors) |errors| try strings(allocator, errors) else null;

    if (source.input) |input| {
        const names = try allocator.alloc(?[]const u8, input.names.len);

        for (input.names, names) |name, *owned| owned.* = if (name) |text| try allocator.dupe(u8, text) else null;

        result.input = .{ .names = names };
    }

    return result;
}
