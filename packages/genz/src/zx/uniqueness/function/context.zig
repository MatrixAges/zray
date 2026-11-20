const std = @import("std");
const zx = @import("zx");
const Function = @import("../function.zig");
const Level = @import("../level.zig").Level;
const Input = std.meta.Child(@import("generated_uniqueness_function_settlement").Input);
const Descriptor = std.meta.Child(@FieldType(Input, "context"));
const Self = @This();
const Metadata = std.meta.Child(@FieldType(Descriptor, "metadata"));
const Layout = std.meta.Child(@FieldType(Metadata, "layout"));
const Usage = std.meta.Child(@FieldType(Metadata, "usage"));

descriptor: Descriptor,
metadata: Metadata,
layout: Layout,
usage: Usage,
normalized: GrowthView,
renewed: GrowthView,
pub fn init(self: *Self, function: *const Function) void {
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

    self.normalized.init(function.growth.normalized);
    self.renewed.init(function.growth.renewed);

    self.descriptor = .{
        .metadata = &self.metadata,
        .normalized = &self.normalized.rows,
        .renewed = &self.renewed.rows,
    };
}

const GrowthView = struct {
    const Rows = std.meta.Child(@FieldType(Descriptor, "normalized"));
    const Stored = std.meta.Child(@typeInfo(@FieldType(Rows, "stored")).optional.child);

    keys: zx.memory.ReadColumn,
    wants: zx.memory.ReadColumn,
    stored: Stored,
    rows: Rows,
    fn init(self: *GrowthView, entries: anytype) void {
        self.rows = .{ .count = entries.len, .stored = null, .items = &.{} };

        if (entries.len == 0) return;

        const Item = std.meta.Elem(@TypeOf(entries));
        const narrow = @hasField(Item, "id");
        const member = if (narrow) "id" else "key";
        self.keys = zx.memory.borrowReadColumn(@FieldType(Item, member), member, entries);
        self.wants = zx.memory.borrowReadColumn(Level, "want", entries);

        self.stored = .{
            .keys = @ptrCast(&self.keys),
            .wants = @ptrCast(&self.wants),
            .bytes = std.mem.sliceAsBytes(entries),
            .wide = !narrow,
        };

        self.rows.stored = &self.stored;
    }
};
