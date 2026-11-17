const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Binding = @import("../../function_import.zig");
const Nodes = @import("../../artifact/nodes.zig");
const Error = @import("../program.zig").Error;
const generated = @import("parser_options").generated_parser;
const Result = struct { members: []const Binding, entry: ?ir.FunctionId };
const Member = struct { binding: Binding, entry: bool };

pub fn link(nodes: *Nodes, source: []const Binding, entry: ?ir.FunctionId) Error!Result {
    if (source.len == 0) return .{ .members = &.{}, .entry = entry };
    if (comptime generated) return publish(nodes, source, entry);

    var members: std.ArrayList(Binding) = .empty;
    var function = entry;

    for (source) |item| {
        const member = try seed(nodes, item);

        if (member.entry) {
            if (function != null) return error.InvalidModule;

            function = member.binding.id;
        } else try members.append(nodes.allocator, member.binding);
    }

    return .{ .members = members.items, .entry = function };
}

fn publish(nodes: *Nodes, source: []const Binding, entry: ?ir.FunctionId) Error!Result {
    const rule = @import("generated_source_link_members");
    const storage = @import("generated_source_member_storage");
    const Input = std.meta.Child(rule.Input);
    const Mapping = std.meta.Child(@FieldType(Input, "functions"));
    const memory = zx.memory;
    const functions = @import("../../artifact/nodes/remap.zig").idMapping(Mapping, nodes.functions);
    const names = memory.borrowTextColumn("name", source);
    const intrinsics = memory.borrowOptionalU8Column("intrinsic", source);

    const shape: std.meta.Child(storage.Input) = .{
        .names = @ptrCast(&names),
        .intrinsics = @ptrCast(&intrinsics),
        .count = source.len,
    };

    const needed = zx.columns.invoke(storage.executeValue, nodes.allocator, &shape) catch unreachable;
    const members: []Binding = if (needed) try nodes.allocator.alloc(Binding, source.len) else &.{};

    errdefer nodes.allocator.free(members);

    const ids = memory.borrowOptionalU32Column("id", source);
    const inputs = memory.borrowOptionalU32Column("input_type", source);
    const outputs = memory.borrowOptionalU32Column("output_type", source);
    const out_names = memory.borrowWriteColumn([]const u8, "name", members);
    const out_ids = memory.borrowWriteColumn(?u32, "id", members);
    const out_inputs = memory.borrowWriteColumn(?u32, "input_type", members);
    const out_outputs = memory.borrowWriteColumn(?u32, "output_type", members);
    const out_intrinsics = memory.borrowWriteColumn(?u8, "intrinsic", members);
    const out_namespaces = memory.borrowWriteColumn(?[]const u8, "namespace", members);

    const input: Input = .{
        .source = &.{
            .names = @ptrCast(&names),
            .intrinsics = @ptrCast(&intrinsics),
            .ids = @ptrCast(&ids),
            .inputs = @ptrCast(&inputs),
            .outputs = @ptrCast(&outputs),
            .count = source.len,
        },
        .target = &.{
            .names = @ptrCast(&out_names),
            .intrinsics = @ptrCast(&out_intrinsics),
            .ids = @ptrCast(&out_ids),
            .inputs = @ptrCast(&out_inputs),
            .outputs = @ptrCast(&out_outputs),
            .namespaces = @ptrCast(&out_namespaces),
        },
        .entry = if (entry) |id| @backingInt(id) else null,
        .type_ids = @ptrCast(nodes.types.mapped),
        .functions = &functions,
    };

    const output = zx.columns.invoke(rule.executeValue, nodes.allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const result = output orelse return error.InvalidModule;

    return .{
        .members = members[0..@intCast(result.written)],
        .entry = if (result.entry) |id| @fromBackingInt(id) else null,
    };
}

fn seed(nodes: *Nodes, item: Binding) Error!Member {
    var member = item;

    member.id = if (item.id) |id| try nodes.functionId(id) else null;
    member.input_type = if (item.input_type) |id| try nodes.types.include(id) else null;
    member.output_type = if (item.output_type) |id| try nodes.types.include(id) else null;
    member.name = try nodes.allocator.dupe(u8, item.name);
    member.namespace = null;

    return .{ .binding = member, .entry = member.name.len == 0 and member.intrinsic == null };
}
