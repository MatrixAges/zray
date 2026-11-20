const std = @import("std");
const zx = @import("zx");
const Function = @import("../function.zig");
const Input = std.meta.Child(@import("generated_uniqueness_function_settlement").Input);
const Descriptor = std.meta.Child(@FieldType(Input, "context"));
const Growth = std.meta.Child(std.meta.Child(@FieldType(Descriptor, "normalized")));
const Self = @This();
const Metadata = std.meta.Child(@FieldType(Descriptor, "metadata"));
const Layout = std.meta.Child(@FieldType(Metadata, "layout"));
const Usage = std.meta.Child(@FieldType(Metadata, "usage"));

descriptor: Descriptor,
metadata: Metadata,
layout: Layout,
usage: Usage,
pub fn init(self: *Self, function: *const Function) std.mem.Allocator.Error!void {
    const slots = function.slots;
    const facts = function.facts;

    self.layout = .{ .offsets = slots.offsets, .members = @ptrCast(slots.members), .unwrapped = @ptrCast(slots.unwrapped) };

    self.usage = .{
        .plan = zx.columns.pointer(@FieldType(Usage, "plan"), facts.usage.plan),
        .nodes = zx.columns.pointer(@FieldType(Usage, "nodes"), facts.nodes),
        .regions = zx.columns.pointer(@FieldType(Usage, "regions"), facts.regions),
        .expressions = zx.columns.pointer(@FieldType(Usage, "expressions"), function.expressions),
        .def_loop = facts.definitions.repeated,
        .symbols = function.symbol_count,
        .held = function.summaries.held,
        .written = function.summaries.written,
        .root = 0,
        .slot = 0,
        .observe = false,
    };

    self.metadata = .{
        .expressions = zx.columns.pointer(@FieldType(Metadata, "expressions"), function.expressions),
        .definitions = zx.columns.pointer(@FieldType(Metadata, "definitions"), facts.definitions),
        .layout = &self.layout,
        .counts = slots.counts,
        .parents = facts.repeated.parent,
        .concurrent = facts.repeated.concurrent,
        .usage = &self.usage,
        .states = @ptrCast(facts.usage.states),
        .input = @ptrCast(function.input),
        .output = @ptrCast(function.summaries.output),
        .function_index = @intCast(function.function orelse std.math.maxInt(u32)),
        .record = function.record_reads,
    };

    self.descriptor = .{
        .metadata = &self.metadata,
        .normalized = try growth(function.allocator, function.growth.normalized),
        .renewed = try growth(function.allocator, function.growth.renewed),
    };
}

fn growth(allocator: std.mem.Allocator, entries: anytype) std.mem.Allocator.Error![]const *const Growth {
    const Item = std.meta.Elem(@TypeOf(entries));
    const rows = try allocator.alloc(Growth, entries.len);
    const pointers = try allocator.alloc(*const Growth, rows.len);

    for (entries, rows, pointers) |entry, *row, *pointer| {
        const key = if (comptime @hasField(Item, "id")) @backingInt(entry.id) else entry.key;
        row.* = .{ .key = key, .value = @fromBackingInt(@as(u3, @bitCast(entry.want))) };
        pointer.* = row;
    }

    return pointers;
}
