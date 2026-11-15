const std = @import("std");
const zx = @import("zx");
const State = @import("../state.zig");
const history = @import("../../history.zig");
const columns = @import("../../history/columns.zig");
const generated = @import("rx_options").generated_graph;
const alignment_rule = if (generated) @import("generated_rx_mixed_history_alignment") else void;
const reanalysis = if (generated) @import("generated_rx_mixed_history_assess") else void;
pub const Assessment = if (generated) reanalysis.Output else void;

pub fn matches(state: *const State, previous: *const history.Retained, start: *const history.Checkpoint, earlier: *const history.Checkpoint, current: *const history.Checkpoint) bool {
    if (comptime !generated) {
        return earlier.functions == current.functions and earlier.native_modules == current.native_modules and
            earlier.initializers == current.initializers and earlier.libraries == current.libraries and

            columns.equal(previous.types, start.types, earlier.types, state.types.items.view(), start.types, current.types) and
            columns.equal(previous.origins, start.origins, earlier.origins, state.types.origins.items.view(), start.origins, current.origins);
    }

    var comparison: Comparison = undefined;
    const input = comparison.project(state, previous, start, earlier, current);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(alignment_rule.executeValue, empty.allocator(), &input) catch unreachable;
}

pub fn assess(state: *const State, previous: *const history.Retained, redone: []const bool, index: usize, position: usize, before: *const history.Checkpoint, after: *const history.Checkpoint) Assessment {
    const earlier = previous.boundaries[position..][0..2];
    var comparison: Comparison = undefined;
    const alignment = comparison.project(state, previous, before, &earlier[1], after);
    const edges = state.graph.source_dependencies.?;

    const input: std.meta.Child(reanalysis.Input) = .{
        .alignment = &alignment,
        .compiled_dependency = state.graph.modules.items(.compiled_dependency)[index],
        .dependencies = &.{ .dependencies = edges.targets, .redone = redone, .first = edges.starts[index], .end = edges.ends[index] },
        .functions = &.{
            .first = before.functions,
            .previous_first = earlier[0].functions,
            .linked = state.finished.present[index] and previous.finished.present[index],
            .store = state.graph.sources.at(index) == .store,
        },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(reanalysis.executeValue, empty.allocator(), &input) catch unreachable;
}

const Comparison = struct {
    const Input = std.meta.Child(alignment_rule.Input);
    const Pair = std.meta.Child(@FieldType(Input, "columns"));
    const View = std.meta.Child(@FieldType(Pair, "left"));
    const Extent = std.meta.Child(@FieldType(Input, "extent_left"));
    left: ViewColumns,
    right: ViewColumns,
    left_view: View,
    right_view: View,
    left_extent: Extent,
    right_extent: Extent,
    pair: Pair,
    fn project(self: *Comparison, state: *const State, previous: *const history.Retained, start: *const history.Checkpoint, earlier: *const history.Checkpoint, current: *const history.Checkpoint) Input {
        const starts = .{ start.types, start.origins };

        self.left = borrow(.{ previous.types, previous.origins }, starts, .{ earlier.types, earlier.origins });
        self.right = borrow(.{ state.types.items.view(), state.types.origins.items.view() }, starts, .{ current.types, current.origins });
        self.left_view = self.left.view(View);
        self.right_view = self.right.view(View);
        self.left_extent = extent(Extent, earlier);
        self.right_extent = extent(Extent, current);
        self.pair = .{ .left = &self.left_view, .right = &self.right_view, .masks = &.{} };

        return .{ .extent_left = &self.left_extent, .extent_right = &self.right_extent, .columns = &self.pair };
    }
};

pub fn extent(comptime Target: type, value: *const history.Checkpoint) Target {
    return .{
        .functions = value.functions,
        .native_modules = value.native_modules,
        .initializers = value.initializers,
        .libraries = value.libraries,
    };
}

const ViewColumns = struct {
    words: [7][]const u8,
    text: [6][]const []const u8,
    fn view(self: *const ViewColumns, comptime Target: type) Target {
        return .{ .words = &self.words, .tags = &.{}, .options = &.{}, .text = &self.text };
    }
};

fn borrow(tables: anytype, start: anytype, end: @TypeOf(start)) ViewColumns {
    var result: ViewColumns = undefined;
    comptime var word = 0;
    comptime var text = 0;

    inline for (tables, 0..) |table, table_index| {
        inline for (@typeInfo(@TypeOf(table)).@"struct".field_names, 0..) |field, index| {
            const values = @field(table, field)[start[table_index][index]..end[table_index][index]];

            switch (std.meta.Elem(@TypeOf(values))) {
                u8, u32 => {
                    result.words[word] = std.mem.sliceAsBytes(values);
                    word += 1;
                },
                []const u8 => {
                    result.text[text] = values;
                    text += 1;
                },
                else => @compileError("unsupported history column"),
            }
        }
    }

    comptime {
        if (word != @typeInfo(@FieldType(ViewColumns, "words")).array.len or text != @typeInfo(@FieldType(ViewColumns, "text")).array.len) {
            @compileError("history comparison does not cover all columns");
        }
    }

    return result;
}
