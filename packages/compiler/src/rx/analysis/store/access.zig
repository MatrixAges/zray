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

    const positions = try invoke(rule.executeValue, scratch.allocator(), .{
        .source = parsed.source,
        .tree = parsed.output.expressions,
        .root = parsed.output.result,
        .names = scope.names,
    });

    if (positions.len == 0) return &.{};

    const result = try allocator.alloc(Binding, positions.len);

    errdefer allocator.free(result);

    const names = memory.borrowWriteColumn([]const u8, "name", result);
    const paths = memory.borrowWriteColumn([]const u8, "path", result);
    const types = memory.borrowWriteColumn(u32, "type_id", result);
    const publish = @import("generated_rx_store_read_bindings");
    const Input = std.meta.Child(publish.Input);

    const input: Input = .{
        .scope = zx.columns.pointer(@FieldType(Input, "scope"), &scope),
        .positions = positions,
        .names = @ptrCast(&names),
        .paths = @ptrCast(&paths),
        .types = @ptrCast(&types),
    };

    try invoke(publish.executeValue, scratch.allocator(), input);

    return result;
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
