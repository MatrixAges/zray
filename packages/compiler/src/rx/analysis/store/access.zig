const std = @import("std");
const zx = @import("zx");
const Indexed = @import("frontend").ExpressionInput.Indexed;
const Binding = @import("../store.zig").Binding;
const Scope = @import("references.zig").Scope;
const memory = @import("zx").memory;

pub const Setter = union(enum) {
    setter: @import("../call/target.zig").Setter,
    invalid: struct { offset: usize, message: []const u8 },
};

pub fn reads(allocator: std.mem.Allocator, backing: std.mem.Allocator, parsed: Indexed, scope: Scope) std.mem.Allocator.Error![]Binding {
    var arena = std.heap.ArenaAllocator.init(backing);
    var buffer: [std.heap.page_size_min / 8]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const rule = @import("generated_rx_store_reads");
    const Input = std.meta.Child(rule.Input);
    const Destination = std.meta.Child(@FieldType(Input, "output"));
    var bindings: memory.RowOutput(Binding, std.meta.Child(@FieldType(Destination, "fields")), .{}) = undefined;

    bindings.init();
    errdefer allocator.free(bindings.rows());

    const input: Input = .{
        .source = parsed.source,
        .tree = parsed.output.expressions,
        .root = parsed.output.result,
        .scope = zx.columns.pointer(@FieldType(Input, "scope"), &scope),
        .output = &.{ .owner = @ptrCast(&allocator), .rows = @ptrCast(&bindings.buffer), .fields = &bindings.view },
    };

    try invoke(rule.executeIn, scratch.allocator(), input);

    return bindings.rows();
}

pub fn setter(backing: std.mem.Allocator, parsed: Indexed, scope: Scope) std.mem.Allocator.Error!Setter {
    var arena = std.heap.ArenaAllocator.init(backing);
    var buffer: [std.heap.page_size_min / 8]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const selected = try invoke(@import("generated_rx_store_setter").executeValue, scratch.allocator(), .{
        .source = parsed.source,
        .tree = parsed.output.expressions,
        .root = parsed.output.result,
        .scope = &scope,
    });

    if (selected.binding) |binding| return .{ .setter = .{
        .name = binding.name,
        .path = binding.path,
        .type_id = @fromBackingInt(binding.type_id),
    } };

    return .{ .invalid = .{ .offset = @intCast(selected.offset), .message = selected.message.? } };
}

fn invoke(comptime rule: anytype, allocator: std.mem.Allocator, input: anytype) std.mem.Allocator.Error!@typeInfo(@typeInfo(@TypeOf(rule)).@"fn".return_type.?).error_union.payload {
    return zx.columns.invoke(rule, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
