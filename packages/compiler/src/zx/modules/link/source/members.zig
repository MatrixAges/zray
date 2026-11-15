const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Binding = @import("../../function_import.zig");
const Nodes = @import("../../artifact/nodes.zig");
const Error = @import("../program.zig").Error;
const generated = @import("parser_options").generated_parser;
const rule = if (generated) @import("generated_source_link_member") else void;
const Input = if (generated) std.meta.Child(rule.Input) else void;
const Mapping = if (generated) std.meta.Child(@FieldType(Input, "functions")) else void;
const Result = struct { members: []const Binding, entry: ?ir.FunctionId };
const Member = struct { binding: Binding, entry: bool };

pub fn link(nodes: *Nodes, source: []const Binding, entry: ?ir.FunctionId) Error!Result {
    if (source.len == 0) return .{ .members = &.{}, .entry = entry };

    const functions = if (generated) @import("../../artifact/nodes/remap.zig").idMapping(Mapping, nodes.functions) else {};
    var members: std.ArrayList(Binding) = .empty;
    var function = entry;

    for (source) |*item| {
        const member = if (generated) try map(nodes, item, &functions) else try seed(nodes, item.*);

        if (member.entry) {
            if (function != null) return error.InvalidModule;

            function = member.binding.id;
        } else try members.append(nodes.allocator, member.binding);
    }

    return .{ .members = members.items, .entry = function };
}

fn map(nodes: *Nodes, item: *const Binding, functions: *const Mapping) Error!Member {
    const input: Input = .{
        .name = item.name,
        .id = if (item.id) |id| @backingInt(id) else null,
        .input_type = if (item.input_type) |id| @backingInt(id) else null,
        .output_type = if (item.output_type) |id| @backingInt(id) else null,
        .intrinsic = item.intrinsic != null,
        .type_ids = @ptrCast(nodes.types.mapped),
        .functions = functions,
    };

    const selected = zx.columns.invoke(rule.executeValue, nodes.allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const row = selected orelse return error.InvalidModule;

    return .{
        .binding = .{
            .name = row.name,
            .id = if (row.id) |id| @fromBackingInt(id) else null,
            .input_type = if (row.input_type) |id| @fromBackingInt(id) else null,
            .output_type = if (row.output_type) |id| @fromBackingInt(id) else null,
            .intrinsic = item.intrinsic,
        },
        .entry = row.entry,
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
