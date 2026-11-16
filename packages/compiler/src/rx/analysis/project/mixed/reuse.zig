//! Reuses the modules of an earlier analysis (see `../history.zig`). While every module so far appended the same
//! rows as before, the tables stay aligned with the earlier ones, and a module whose source is unchanged and whose
//! dependencies were all reused copies its earlier rows. Analysis reads callee bodies, not only their signatures, and
//! some facts follow calls through every body reached, so a module depending on one whose rows changed, directly or
//! through its own dependencies, is analyzed again too. A module analyzed again into the very rows and link it had
//! before, whose dependencies changed nothing either, changes nothing its dependents read, so they stay reusable. Once a
//! module appends different types, or a different number of rows, every later module is analyzed.
const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const comparisons = @import("frontend").compare_ir;
const State = @import("state.zig");
const history = @import("../history.zig");
const columns = @import("../history/columns.zig");
const project = @import("frontend").project;
const alignment = @import("history/alignment.zig");
const Graph = @FieldType(State, "graph");
const generated = @import("rx_options").generated_graph;
const batch_reuse = generated and @bitSizeOf(usize) == 64 and @alignOf(usize) >= @alignOf(u64);
const Self = @This();

record: ?*history.History,

previous: ?*const history.Retained = null,
derived: history.Frame,
aligned: bool = false,
/// Modules whose rows or link differ from the earlier ones, or that depend on such a module.
redone: []bool = &.{},
digests: history.SourceDigests = .{},
boundaries: []history.Checkpoint = &.{},
pub fn begin(state: *const State, cache: *const project.ParseCache, record: ?*history.History, derived: history.Frame, sources: []const project.Source) std.mem.Allocator.Error!Self {
    const owner = record orelse return .{ .record = null, .derived = derived };
    const count = state.graph.modules.len;

    var self = Self{
        .record = record,
        .derived = derived,
        .redone = try state.allocator.alloc(bool, count),
        .digests = try .init(state.allocator, count),
        .boundaries = try state.allocator.alloc(history.Checkpoint, state.graph.order.len + 1),
    };

    @memset(self.redone, false);

    self.boundaries[0] = checkpoint(state);
    const retained = if (owner.bodies_only) &owner.previous.? else null;
    const paths = state.graph.modules.items(.path);
    const ranges = state.graph.sources;

    // A failed request can replace a parse while the last successful analysis still owns its digest.
    @import("../history/digest.zig").publishSource(cache, paths[0..ranges.zx_count], sources, retained, self.digests);

    if (comptime generated) {
        @import("../history/digest.zig").publish(owner.rx_digests, paths[ranges.zx_count..ranges.rx_end], .{
            .words = self.digests.words[ranges.zx_count..ranges.rx_end],
            .present = self.digests.present[ranges.zx_count..ranges.rx_end],
        });
    } else {
        for (paths[ranges.zx_count..ranges.rx_end], ranges.zx_count..) |path, index| {
            const digest = owner.rxDigest(path);

            self.digests.set(index, if (digest != null) &digest.? else null);
        }
    }

    @memset(self.digests.present[ranges.rx_end..], false);

    const previous = if (owner.previous) |*value| value else return self;

    self.previous = previous;
    self.aligned = matches(state, previous, &owner.shape, &self.boundaries[0]);

    return self;
}

/// Restores the reusable prefix of the current window and returns the next position to analyze.
pub fn reuse(self: *Self, state: *State, first: usize, limit: usize) std.mem.Allocator.Error!usize {
    const previous = self.previous orelse return first;

    if (!self.aligned) return first;

    const order = state.graph.order;
    var position = first;

    if (comptime batch_reuse) {
        const admission = @import("history/admit.zig");
        const inputs = admission.Borrowed.init(state, previous, self.digests, self.redone);
        const retained = inputs.view();

        while (position < limit) : (position += 1) {
            const prefix = admission.scan(state, &retained, position, limit);

            position = @intCast(prefix.position);

            if (!prefix.inspect_source) break;
            if (!admission.confirm(state, &self.derived, previous, order[position])) break;
        }
    } else {
        while (position < limit and self.reusable(state, order[position], position)) : (position += 1) {}
    }

    if (position == first) return first;

    const start = &previous.boundaries[first];
    const end = &previous.boundaries[position];

    try columns.transplant(state.allocator, .{
        .{ .storage = &state.types.items, .source = previous.types, .start = start.types, .end = end.types },
        .{ .storage = &state.types.origins.items, .source = previous.origins, .start = start.origins, .end = end.origins },
        .{
            .storage = &state.functions,
            .source = previous.functions,
            .start = @as(columns.Lengths(ir.FunctionStorage), @splat(start.functions)),
            .end = @as(columns.Lengths(ir.FunctionStorage), @splat(end.functions)),
        },
    });

    if (comptime batch_reuse) {
        @import("history/publish.zig").copy(state, self.boundaries, previous, first, position);
    } else {
        for (order[first..position]) |index| state.finished.retain(previous.finished, index);

        @memcpy(self.boundaries[first + 1 .. position + 1], previous.boundaries[first + 1 .. position + 1]);
    }

    state.verified = end.functions;
    self.record.?.reused += position - first;

    return position;
}

/// Whether `reuse` can copy `index`'s rows while the tables stay aligned until its turn.
pub fn reusable(self: *const Self, state: *const State, index: usize, position: usize) bool {
    const previous = self.previous orelse return false;

    if (!self.aligned or index == state.graph.entry) return false;

    if (comptime generated) {
        return @import("history/admit.zig").reusable(state, &self.derived, previous, self.redone, self.digests, index, position);
    }

    if (!self.unchanged(state, index)) return false;

    const start = &previous.boundaries[position];
    const end = &previous.boundaries[position + 1];

    return start.native_modules == end.native_modules and start.initializers == end.initializers and start.libraries == end.libraries;
}

/// Records that `index` was analyzed, and whether the tables still match the earlier analysis after it.
pub fn analyzed(self: *Self, state: *const State, index: usize, position: usize) void {
    const owner = self.record orelse return;
    const start = &self.boundaries[position];
    const end = &self.boundaries[position + 1];

    self.redone[index] = true;
    end.* = checkpoint(state);
    owner.analyzed += 1;

    const previous = self.previous orelse return;

    if (!self.aligned) return;

    if (comptime generated) {
        switch (alignment.assess(state, previous, self.redone, index, position, start, end)) {
            .Misaligned => self.aligned = false,
            .Changed => {},
            .Unchanged => self.redone[index] = false,
            .CompareFunctions => self.redone[index] = !repeated(state, previous, index, start.functions, end.functions),
        }

        return;
    }

    const earlier = previous.boundaries[position..][0..2];

    self.aligned = alignment.matches(state, previous, start, &earlier[1], end);

    if (!self.aligned or self.reaches(state, index)) return;

    if (state.graph.sources.at(index) == .store or
        (earlier[0].functions == start.functions and repeated(state, previous, index, start.functions, end.functions)))
    {
        self.redone[index] = false;
    }
}

/// Whether a dependency of `index` changed.
fn reaches(self: *const Self, state: *const State, index: usize) bool {
    if (state.graph.modules.items(.compiled_dependency)[index]) return true;

    const dependencies = state.graph.source_dependencies.?.at(index);

    for (dependencies) |dependency| if (self.redone[@intCast(dependency)]) return true;

    return false;
}

/// Whether `index`, analyzed again into tables still aligned, appended the very function rows and produced the very
/// link it had before, down to the bodies they point to.
fn repeated(state: *const State, previous: *const history.Retained, index: usize, start: usize, end: usize) bool {
    const current = state.finished.get(index) orelse return false;
    const earlier = previous.finished.get(index) orelse return false;
    const left = previous.functions;
    const right = state.functions.view();

    if (comptime generated) {
        return @import("history/linked.zig").equal(&current, &earlier) and
            comparisons.headers(&left, &right, start, end) and comparisons.bodies(&left, &right, start, end);
    }

    if (!columns.same(current, earlier)) return false;

    inline for (@typeInfo(ir.FunctionTable).@"struct".field_names) |name| {
        const Element = std.meta.Elem(@FieldType(ir.FunctionTable, name));
        const shared = comptime @typeInfo(Element) == .pointer and @typeInfo(Element).pointer.size == .one;

        if (shared) {
            for (@field(left, name)[start..end], @field(right, name)[start..end]) |a, b| if (!columns.same(a.*, b.*)) return false;
        } else if (!columns.same(@field(left, name)[start..end], @field(right, name)[start..end])) return false;
    }

    return true;
}

/// Leaves this analysis for the next one.
pub fn finish(self: *const Self, state: *const State, selected: []const @import("rx").ModuleSource, sources: []const @import("frontend").project.Source) void {
    const owner = self.record orelse return;

    owner.next = .{
        .frame = owner.frame,
        .shape = owner.shape,
        .modules = selected,
        .sources = sources,
        .derived = self.derived,
        .digests = self.digests,
        .boundaries = self.boundaries,
        .finished = state.finished,
        .types = state.types.items.view(),
        .origins = state.types.origins.items.view(),
        .functions = state.functions.view(),
    };
}

/// A module is unchanged when its source is and so are its dependencies; aligned tables imply an unchanged shape. An RX
/// module's signature is resolved over every RX module at once, so it must also have resolved as before.
fn unchanged(self: *const Self, state: *const State, index: usize) bool {
    const source = state.graph.sources.at(index);
    const previous = self.previous.?;

    if (source == .store) {
        const before = previous.derived.dependencies.sources.at(index);

        return before == .store and columns.same(previous.derived.stores[before.store].node, self.derived.stores[source.store].node) and !self.reaches(state, index);
    }

    const earlier = previous.digests.at(index) orelse return false;
    const current = self.digests.at(index) orelse return false;

    if (!std.mem.eql(u8, earlier, current)) return false;

    if (source == .rx) {
        const before = previous.derived.dependencies.sources.at(index);

        if (before != .rx or !columns.same(previous.derived.resolved[before.rx], self.derived.resolved[source.rx])) return false;
    }

    return !self.reaches(state, index);
}

/// Whether this analysis starts from the tables the earlier one started from, over the same modules in the same order.
fn matches(state: *const State, previous: *const history.Retained, shape: *const [32]u8, initial: *const history.Checkpoint) bool {
    const earlier = previous.derived.dependencies;
    const current = state.graph;

    if (!matchesGraph(earlier, current, &previous.shape, shape, &previous.boundaries[0], initial)) return false;

    const start: history.Checkpoint = .{
        .types = @splat(0),
        .origins = @splat(0),
        .functions = 0,
        .native_modules = 0,
        .initializers = 0,
        .libraries = 0,
    };

    if (!alignment.matches(state, previous, &start, initial, initial)) return false;

    return signatures(previous.functions, state.functions.view(), initial.functions);
}

fn matchesGraph(earlier: Graph, current: Graph, earlier_shape: *const [32]u8, current_shape: *const [32]u8, earlier_boundary: *const history.Checkpoint, current_boundary: *const history.Checkpoint) bool {
    const earlier_paths = earlier.modules.items(.path);
    const current_paths = current.modules.items(.path);

    if (comptime generated) {
        const rule = @import("generated_rx_mixed_history_start");
        const Input = std.meta.Child(rule.Input);
        const Boundaries = std.meta.Child(@FieldType(Input, "boundary"));
        const Checkpoint = std.meta.Child(@FieldType(Boundaries, "before"));
        const Extent = std.meta.Child(@FieldType(Checkpoint, "extent"));
        const earlier_extent = alignment.extent(Extent, earlier_boundary);
        const current_extent = alignment.extent(Extent, current_boundary);
        const earlier_view = checkpointView(Checkpoint, earlier_boundary, &earlier_extent);
        const current_view = checkpointView(Checkpoint, current_boundary, &current_extent);

        const input: Input = .{
            .inputs = &.{
                .earlier = earlier_shape,
                .current = current_shape,
                .earlier_count = earlier_paths.len,
                .current_count = current_paths.len,
            },
            .boundary = &.{ .before = &earlier_view, .after = &current_view },
            .graph = &.{
                .earlier_order = std.mem.sliceAsBytes(earlier.order),
                .current_order = std.mem.sliceAsBytes(current.order),
                .earlier_paths = earlier_paths,
                .current_paths = current_paths,
                .shared_paths = earlier_paths.ptr == current_paths.ptr,
            },
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
    }

    if (!@import("../history/admission.zig").sameInputs(earlier_shape, current_shape, earlier_paths.len, current_paths.len)) return false;
    if (!earlier_boundary.eql(current_boundary.*)) return false;
    if (!std.mem.eql(usize, earlier.order, current.order)) return false;
    if (earlier_paths.ptr == current_paths.ptr) return true;
    for (earlier_paths, current_paths) |before, after| if (!zx.bytes.equal(before, after)) return false;

    return true;
}

fn checkpointView(comptime Target: type, value: *const history.Checkpoint, counts: @FieldType(Target, "extent")) Target {
    return .{
        .types = std.mem.asBytes(&value.types),
        .origins = std.mem.asBytes(&value.origins),
        .extent = counts,
    };
}

/// Compares the function rows' signature columns; the tables each row points to belong to one analysis.
fn signatures(left: ir.FunctionTable, right: ir.FunctionTable, count: usize) bool {
    if (comptime generated) {
        return comparisons.headers(&left, &right, 0, count);
    }

    inline for (@typeInfo(ir.FunctionTable).@"struct".field_names) |name| {
        const Element = std.meta.Elem(@FieldType(ir.FunctionTable, name));
        const shared = comptime @typeInfo(Element) == .pointer and @typeInfo(Element).pointer.size == .one;

        if (!shared and !columns.same(@field(left, name)[0..count], @field(right, name)[0..count])) return false;
    }

    return true;
}

fn checkpoint(state: *const State) history.Checkpoint {
    return .{
        .types = columns.measure(&state.types.items),
        .origins = columns.measure(&state.types.origins.items),
        .functions = state.functions.count(),
        .native_modules = state.native_modules.count(),
        .initializers = state.initializers.items.len,
        .libraries = state.libraries.count(),
    };
}
