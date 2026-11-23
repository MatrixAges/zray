const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const State = @import("../host.zig").State;
const Request = @import("../abi.zig").Request;
const fixed = @import("../fixed.zig");
const Storage = ir.ExpressionStorage;
const Work = std.meta.Child(@FieldType(Request, "operands"));
const Allocation = std.meta.Child(@FieldType(Work, "allocation"));
pub const Route = @FieldType(Work, "route");
const Fixed = std.meta.Child(@FieldType(Work, "fixed"));
const Sequence = std.meta.Child(@FieldType(Work, "sequence"));
const Range = std.meta.Child(@FieldType(Sequence, "range"));
const SourceRange = std.meta.Child(@FieldType(Sequence, "source_range"));
const Symbols = std.meta.Child(@FieldType(Fixed, "symbols"));
const Column = std.meta.Child(std.meta.Elem(@FieldType(Fixed, "columns")));
const Metadata = std.meta.Child(@typeInfo(@FieldType(Fixed, "metadata")).optional.child);

const Writer = union(Route) {
    Fixed: Fixed,
    Sequence: Sequence,
    Collection: std.meta.Child(@FieldType(Work, "collection")),
    Transform: std.meta.Child(@FieldType(Work, "transform")),
    Scope: std.meta.Child(@FieldType(Work, "scope")),
    Selection: std.meta.Child(@FieldType(Work, "selection")),
    Object: std.meta.Child(@FieldType(Work, "object")),
};

fn Group(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        descriptors: [capacity]memory.ColumnRange = undefined,
        tails: [capacity][]const u8 = undefined,
        active: memory.ColumnRanges = undefined,
        len: usize = 0,
        fn bind(self: *Self, column: anytype, count: usize, comptime bytes: bool) *anyopaque {
            const index = self.len;
            const tail = &self.tails[index];
            self.descriptors[index] = memory.bindColumnRange(column, count, @ptrCast(tail), bytes);
            self.len = index + 1;

            return @ptrCast(tail);
        }
        fn freeze(self: *Self) ?*const memory.ColumnRanges {
            if (self.len == 0) return null;

            self.active = self.descriptors[0..self.len];

            return &self.active;
        }
    };
}

pub const Frame = struct {
    input: Work = undefined,
    allocation: Allocation = undefined,
    header: Group(7) = .{},
    members: Group(3) = .{},
    evaluation: Group(1) = .{},
    writer: Writer = undefined,
    symbols: Symbols = undefined,
    ranges: [2]Range = undefined,
    source_ranges: [2]SourceRange = undefined,
    columns: [5]Column = undefined,
    column_views: [5]*const Column = undefined,
    metadata: Metadata = undefined,
};

pub fn prepareExpressionOperand(handle: *const anyopaque, index: u32, route: Route) error{InvalidModule}!bool {
    const state = State.borrow(handle);
    const source = &state.program.expressions;
    const kind = source.kinds[index];

    if (kind == .None or kind == .Unit) return false;

    const frame = &state.operands;
    const builder = state.builder;
    frame.header.len = 0;
    frame.members.len = 0;
    frame.evaluation.len = 0;
    frame.symbols = @import("../operands.zig").symbolView(Symbols, &state.mapping);

    const binding: Binding = .{
        .frame = frame,
        .storage = &builder.expressions,
        .source = source,
        .row = source.payloads[index],
        .mapping = state.mapping.expressions[0..index],
        .kind = kind,
    };

    frame.input.route = route;
    frame.input.allocation = &frame.allocation;

    switch (route) {
        .Fixed => try fixed.visit(kind, binding),
        .Sequence => binding.sequence(),
        .Collection => binding.collection(),
        .Transform => binding.transform(),
        .Scope => binding.scope(),
        .Selection => binding.selection(),
        .Object => binding.object(),
    }

    frame.allocation = .{
        .resource = @ptrCast(&builder.allocator),
        .header = @ptrCast(frame.header.freeze().?),
        .members = if (frame.members.freeze()) |group| @ptrCast(group) else null,
        .evaluation = if (frame.evaluation.freeze()) |group| @ptrCast(group) else null,
    };

    return true;
}

pub fn requireExpressionOperand(valid: bool) error{InvalidModule}!void {
    if (!valid) return error.InvalidModule;
}

const Binding = struct {
    pub const Output = error{InvalidModule}!void;
    frame: *Frame,
    storage: *Storage,
    source: *const ir.ExpressionTable,
    row: u32,
    mapping: []const u32,
    kind: std.meta.Elem(@FieldType(ir.ExpressionTable, "kinds")),
    pub fn mapped(self: Binding, comptime payload: fixed.Payload) Output {
        const frame = self.frame;
        const fields = comptime payload.expressions ++ payload.symbols ++ payload.raw;

        inline for (fields, 0..) |name, slot| {
            frame.columns[slot] = .{
                .source = @field(self.source, name),
                .target = @ptrCast(frame.header.bind(&@field(self.storage, name), 1, false)),
            };

            frame.column_views[slot] = &frame.columns[slot];
        }

        const optional = if (comptime payload.optional) |name| @field(self.source, name)[self.row] else null;
        const target: ?*anyopaque = if (comptime payload.optional) |name| frame.header.bind(&@field(self.storage, name), 1, false) else null;

        if (comptime payload.metadata.len != 0) {
            const name = payload.metadata[0];
            const values = @field(self.source, name);

            comptime std.debug.assert(@sizeOf(std.meta.Elem(@TypeOf(values))) == 1 and payload.metadata.len == 1);

            frame.metadata = .{
                .source = std.mem.sliceAsBytes(values),
                .target = @ptrCast(frame.header.bind(&@field(self.storage, name), 1, true)),
            };
        }

        frame.writer = .{ .Fixed = .{
            .kind = @fromBackingInt(@intCast(@backingInt(self.kind))),
            .columns = frame.column_views[0..fields.len],
            .row = self.row,
            .mapping = self.mapping,
            .symbols = &frame.symbols,
            .optional_symbol = optional,
            .optional_target = if (target) |column| @ptrCast(column) else null,
            .metadata = if (comptime payload.metadata.len != 0) &frame.metadata else null,
        } };

        frame.input.fixed = &frame.writer.Fixed;
    }
    fn sequence(self: Binding) void {
        const frame = self.frame;
        const source = self.source;
        const storage = self.storage;
        const selected = self.sourceRange("sequence", 0);
        const range = self.bindRange("sequence", 0, storage.sequence_items.items.len);

        frame.writer = .{ .Sequence = .{
            .source = source.sequence_items,
            .source_range = selected,
            .mapping = self.mapping,
            .target = @ptrCast(frame.members.bind(&storage.sequence_items, selected.count, false)),
            .range = range,
        } };

        frame.input.sequence = &frame.writer.Sequence;
    }
    fn collection(self: Binding) void {
        const frame = self.frame;
        const source = self.source;
        const storage = self.storage;
        const selected = self.sourceRange("collection", 0);
        const kinds = frame.header.bind(&storage.collection_kinds, 1, true);
        const targets = frame.header.bind(&storage.collection_targets, 1, false);
        const range = self.bindRange("collection", 0, storage.collection_arguments.items.len);

        frame.writer = .{ .Collection = .{
            .target = source.collection_targets[self.row],
            .kind = @backingInt(source.collection_kinds[self.row]),
            .mapping = self.mapping,
            .arguments = source.collection_arguments,
            .source_range = selected,
            .target_arguments = @ptrCast(frame.members.bind(&storage.collection_arguments, selected.count, false)),
            .kinds = @ptrCast(kinds),
            .targets = @ptrCast(targets),
            .range = range,
        } };

        frame.input.collection = &frame.writer.Collection;
    }

    fn transform(self: Binding) void {
        const frame = self.frame;
        const source = self.source;
        const storage = self.storage;
        const selected = self.sourceRange("transform", 0);
        const kinds = frame.header.bind(&storage.transform_kinds, 1, true);
        const targets = frame.header.bind(&storage.transform_targets, 1, false);
        const bodies = frame.header.bind(&storage.transform_bodies, 1, false);
        const initials = frame.header.bind(&storage.transform_initials, 1, false);
        const range = self.bindRange("transform", 0, storage.transform_parameters.items.len);

        frame.writer = .{ .Transform = .{
            .target = source.transform_targets[self.row],
            .body = source.transform_bodies[self.row],
            .initial = source.transform_initials[self.row],
            .kind = @backingInt(source.transform_kinds[self.row]),
            .mapping = self.mapping,
            .symbols = &frame.symbols,
            .parameters = source.transform_parameters,
            .source_range = selected,
            .target_parameters = @ptrCast(frame.members.bind(&storage.transform_parameters, selected.count, false)),
            .kinds = @ptrCast(kinds),
            .targets = @ptrCast(targets),
            .bodies = @ptrCast(bodies),
            .initials = @ptrCast(initials),
            .range = range,
        } };

        frame.input.transform = &frame.writer.Transform;
    }

    fn scope(self: Binding) void {
        const frame = self.frame;
        const source = self.source;
        const storage = self.storage;
        const selected = self.sourceRange("scope", 0);
        const results = frame.header.bind(&storage.scope_results, 1, false);
        const range = self.bindRange("scope", 0, storage.scope_symbols.items.len);
        const target_symbols = frame.members.bind(&storage.scope_symbols, selected.count, false);
        const target_values = frame.members.bind(&storage.scope_values, selected.count, false);
        const target_borrows = frame.members.bind(&storage.scope_borrows, selected.count, true);

        frame.writer = .{ .Scope = .{
            .result = source.scope_results[self.row],
            .mapping = self.mapping,
            .symbols = &frame.symbols,
            .binding_symbols = source.scope_symbols,
            .binding_values = source.scope_values,
            .borrows = std.mem.sliceAsBytes(source.scope_borrows),
            .source_range = selected,
            .target_symbols = @ptrCast(target_symbols),
            .target_values = @ptrCast(target_values),
            .target_borrows = @ptrCast(target_borrows),
            .results = @ptrCast(results),
            .range = range,
        } };

        frame.input.scope = &frame.writer.Scope;
    }
    fn selection(self: Binding) void {
        const frame = self.frame;
        const source = self.source;
        const storage = self.storage;
        const selected = self.sourceRange("match", 0);
        const subjects = frame.header.bind(&storage.match_subjects, 1, false);
        const fallbacks = frame.header.bind(&storage.match_fallbacks, 1, false);
        const range = self.bindRange("match", 0, storage.match_conditions.items.len);
        const target_conditions = frame.members.bind(&storage.match_conditions, selected.count, false);
        const target_results = frame.members.bind(&storage.match_results, selected.count, false);

        frame.writer = .{ .Selection = .{
            .subject = source.match_subjects[self.row],
            .fallback = source.match_fallbacks[self.row],
            .mapping = self.mapping,
            .conditions = source.match_conditions,
            .results = source.match_results,
            .source_range = selected,
            .target_conditions = @ptrCast(target_conditions),
            .target_results = @ptrCast(target_results),
            .subjects = @ptrCast(subjects),
            .fallbacks = @ptrCast(fallbacks),
            .range = range,
        } };

        frame.input.selection = &frame.writer.Selection;
    }
    fn object(self: Binding) void {
        const frame = self.frame;
        const source = self.source;
        const storage = self.storage;
        const fields = self.sourceRange("object", 0);
        const evaluation = self.sourceRange("object_evaluation", 1);
        const field_range = self.bindRange("object", 0, storage.object_field_indices.items.len);
        const evaluation_range = self.bindRange("object_evaluation", 1, storage.object_evaluation_values.items.len);
        const indices = frame.members.bind(&storage.object_field_indices, fields.count, true);

        frame.writer = .{ .Object = .{
            .mapping = self.mapping,
            .fields = source.object_field_values,
            .indices = std.mem.sliceAsBytes(source.object_field_indices),
            .index_width = @sizeOf(u32),
            .evaluation = source.object_evaluation_values,
            .source_fields = fields,
            .source_evaluation = evaluation,
            .target_fields = @ptrCast(frame.members.bind(&storage.object_field_values, fields.count, false)),
            .target_evaluation = @ptrCast(frame.evaluation.bind(&storage.object_evaluation_values, evaluation.count, false)),
            .target_indices = @ptrCast(indices),
            .field_range = field_range,
            .evaluation_range = evaluation_range,
        } };

        frame.input.object = &frame.writer.Object;
    }
    fn sourceRange(self: Binding, comptime name: []const u8, slot: usize) *const SourceRange {
        const result = &self.frame.source_ranges[slot];

        result.* = .{
            .first = @field(self.source, name ++ "_first")[self.row],
            .count = @field(self.source, name ++ "_count")[self.row],
        };

        return result;
    }
    fn bindRange(self: Binding, comptime name: []const u8, slot: usize, first: usize) *const Range {
        const result = &self.frame.ranges[slot];
        const header = &self.frame.header;
        const firsts = header.bind(&@field(self.storage, name ++ "_first"), 1, false);
        const counts = header.bind(&@field(self.storage, name ++ "_count"), 1, false);

        result.* = .{
            .firsts = @ptrCast(firsts),
            .counts = @ptrCast(counts),
            .first = @intCast(first),
        };

        return result;
    }
};
