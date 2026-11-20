const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Variant = @import("requests.zig").Variant;
const entry = @import("generated_function_reference");
const Input = std.meta.Child(entry.Input);
const Target = std.meta.Child(@FieldType(Input, "target"));

pub fn prepare(self: *Lower, id: zx.ir.FunctionId, variant: Variant) Lower.Error!Target {
    const module = if (self.function_modules) |modules| modules[@backingInt(id)] else null;

    if (module == null) try self.function_requests.add(self.allocator, id, variant);

    return .{
        .id = @backingInt(id),
        .variant = switch (variant) {
            .regular => .Regular,
            .value => .Value,
        },
        .module = module,
        .recursive = id == self.self_function,
        .local_regular = self.local_regular_function,
    };
}

pub fn lower(self: *Lower, id: zx.ir.FunctionId, variant: Variant) Lower.Error!node.ExpressionId {
    const target = try prepare(self, id, variant);

    const input: Input = .{
        .target = &target,
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .identifiers = 0,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = memory.allocator();
    const output = entry.executeIn(temporary, &input) catch |err| return failure(err);

    try publish(self, temporary, output.nodes, target.module == null);

    return @fromBackingInt(output.root);
}

/// Generated function names are temporary; module paths and ABI member names already outlive the body.
pub fn publish(self: *Lower, scratch: std.mem.Allocator, source: anytype, owns_name: bool) Lower.Error!void {
    var rows = source.*;

    if (owns_name) {
        const names = try scratch.dupe([]const u8, rows.identifier);
        const last = names.len - 1;
        names[last] = try self.allocator.dupe(u8, names[last]);
        rows.identifier = names;
    }

    @import("../../node/import_rows.zig").appendBorrowingText(self.allocator, &self.builder.nodes.expressions, &rows) catch |err| return failure(err);
}

pub fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid function reference emission"),
    };
}
