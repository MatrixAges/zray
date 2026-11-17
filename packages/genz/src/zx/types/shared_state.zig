const std = @import("std");
const zx = @import("zx");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const rows = @import("../../node/import_rows.zig");
const Lower = @import("../lower.zig");
const Cache = @import("cache.zig");
const generated = @import("generated_shared_state");
const Input = std.meta.Child(generated.Input);
const Source = std.meta.Child(@FieldType(Input, "source"));
const Mode = @FieldType(std.meta.Child(@FieldType(Source, "request")), "mode");

pub fn build(self: *Lower, index: usize, mode: Mode) Lower.Error!void {
    const Abi = std.meta.Child(@FieldType(Source, "abi"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Abi, "types")), self.program.types);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const abi: Abi = .{
        .types = &types,
        .names = self.type_names,
        .cached = view.slice(@FieldType(Abi, "cached"), @as([]const node.ExpressionId, self.abi_types)),
        .root = @intCast(index),
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
    };

    const source: Source = .{
        .abi = &abi,
        .selected = self.state_plan.selected,
        .borrowed = self.state_plan.borrowed,
        .keys = std.mem.sliceAsBytes(self.state_plan.keys),
        .states = view.slice(@FieldType(Source, "states"), @as([]const node.ExpressionId, self.state_types)),
        .state_layouts = view.slice(@FieldType(Source, "state_layouts"), @as([]const node.ExpressionId, self.state_layouts)),
        .views = view.slice(@FieldType(Source, "views"), @as([]const node.ExpressionId, self.view_types)),
        .abi_layouts = view.slice(@FieldType(Source, "abi_layouts"), @as([]const node.ExpressionId, self.abi_layouts)),
        .request = &.{ .id = @intCast(index), .mode = mode },
    };

    const Columns = std.meta.Child(@FieldType(Input, "columns"));
    const target = Cache.borrow(self);
    const tracked = target.touch(Cache.Touched(Columns));
    const columns = target.columns(Columns, &tracked);
    const input: Input = .{ .source = &source, .columns = &columns };

    const output = zx.columns.invoke(generated.executeValue, buffered.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) return error.OutOfMemory;

    const Expressions = std.meta.Child(std.meta.Child(@FieldType(std.meta.Child(generated.Output), "segments")));

    for (output.segments) |segment| {
        var expressions: Expressions = undefined;

        inline for (@typeInfo(Expressions).@"struct".field_names) |name| @field(expressions, name) = @field(segment, name);

        const imported = rows.append(self.allocator, &self.builder.nodes.expressions, &expressions);

        imported catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAst => unreachable,
        };
    }
}
