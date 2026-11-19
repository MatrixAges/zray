const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const strings = @import("native.zig").strings;
const Error = std.mem.Allocator.Error || error{InvalidModule};
const columns = @import("../../artifact/materializing/publication/columns.zig");
const publish = @import("generated_compiled_publish");
pub const Request = @typeInfo(@TypeOf(publish.executeState)).@"fn".param_types[1].?;
const Result = @typeInfo(@typeInfo(@TypeOf(publish.executeState)).@"fn".return_type.?).error_union.payload;
const Input = @FieldType(Request, "functions");
const Columns = @FieldType(Input, "target");
const Mapping = @FieldType(Input, "mapping");
const indirect_mapping = @typeInfo(Mapping) == .pointer;

pub const Context = struct {
    types: []const u32,
    natives: []const u32,
    first: usize,
    instance: []const u8,
};

pub const View = struct {
    completed: [1]u64,
    progress: []u64,
    slots: [@typeInfo(ir.FunctionStorage).@"struct".field_names.len]*usize,
    lengths: zx.memory.ColumnLengths,
    mapping: if (indirect_mapping) std.meta.Child(Mapping) else void,
    input: Input,
    pub fn init(self: *View, functions: *ir.FunctionStorage, source: ir.FunctionTable, context: Context) void {
        const tails = functions.reservedTail(source.count());

        self.completed = .{0};
        self.progress = &self.completed;
        self.slots = zx.memory.borrowColumnLengths(functions);
        self.lengths = &self.slots;

        if (indirect_mapping) self.mapping = .{ .types = context.types, .natives = context.natives };

        self.input = .{
            .source = columns.borrow(@FieldType(Input, "source"), source, false),
            .target = columns.borrow(Columns, tails, true),
            .mapping = if (indirect_mapping) &self.mapping else columns.borrow(Mapping, context, false),
            .first = context.first,
            .instance = context.instance,
            .progress = @ptrCast(&self.progress),
            .lengths = @ptrCast(&self.lengths),
        };
    }

    pub fn check(self: *const View, output: Result) Error!void {
        switch (output.status) {
            .Exhausted => return error.OutOfMemory,
            .Invalid => return error.InvalidModule,
            .Complete => columns.checkBorrow(self.input.target, output.columns.?),
        }

        std.debug.assert(self.completed[0] == self.input.source.files.items.len);
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
