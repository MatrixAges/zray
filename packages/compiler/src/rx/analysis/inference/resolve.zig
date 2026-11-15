const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const Nodes = @import("nodes.zig");

pub const Workspace = struct {
    local_frames: [16]u64 = undefined,
    local_values: [32]u32 = undefined,
    extra_frames: std.ArrayList(u64) = .empty,
    extra_values: std.ArrayList(u32) = .empty,
    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        self.extra_frames.deinit(allocator);
        self.extra_values.deinit(allocator);
    }
};

pub fn resolve(graph: *Graph, value: Graph.Id, workspace: *Workspace) zx.Error!zx.ir.TypeId {
    if (!@import("rx_options").generated_graph) return @import("resolve/seed.zig").resolve(graph, value, 0);

    const rows = graph.nodes.slice();
    const index = @backingInt(graph.root(value));

    if (rows.items(.kind)[index] == .Known) return @fromBackingInt(rows.items(.argument)[index]);

    return run(graph, rows, index, workspace);
}

fn run(graph: *Graph, rows: Nodes.Storage.Slice, root: u32, workspace: *Workspace) zx.Error!zx.ir.TypeId {
    const generated = @import("generated_rx_resolve_type");
    const Request = @typeInfo(@TypeOf(generated.executeState)).@"fn".param_types[1].?;
    const View = std.meta.Child(@FieldType(Request, "graph"));
    const Publication = std.meta.Child(@FieldType(Request, "publication"));
    const kinds = rows.items(.kind);
    const arguments = rows.items(.argument);
    const kind_bytes = std.mem.sliceAsBytes(kinds);
    const revision: []u64 = (&graph.object_revision)[0..1];

    comptime {
        if (@sizeOf(Nodes.Kind) != @sizeOf(u8)) @compileError("inference kind column must store one byte per row");
    }

    const view: View = .{
        .kinds = kinds,
        .arguments = arguments,
        .members = rows.items(.members),
        .allowed = rows.items(.allowed),
        .fallback = rows.items(.fallback),
    };

    const publication: Publication = .{
        .kinds = @ptrCast(&kind_bytes),
        .arguments = @ptrCast(&arguments),
        .revision = @ptrCast(&revision),
        .known_kind = @backingInt(Nodes.Kind.Known),
    };

    var frames: []u64 = if (workspace.extra_frames.capacity == 0) &workspace.local_frames else workspace.extra_frames.allocatedSlice();
    var values: []u32 = if (workspace.extra_values.capacity == 0) &workspace.local_values else workspace.extra_values.allocatedSlice();
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const parents = graph.parents();

    var state: Request = .{
        .graph = &view,
        .publication = &publication,
        .parents = @ptrCast(&parents),
        .frames = @ptrCast(&frames),
        .values = @ptrCast(&values),
        .frame_capacity = frames.len,
        .value_capacity = values.len,
        .depth = 0,
        .used = 0,
        .count = 0,
        .node = root,
        .completed = null,
        .route = .Search,
    };

    while (true) {
        state = generated.executeState(empty.allocator(), state) catch |err| switch (err) {
            error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
            else => unreachable,
        };

        switch (state.route) {
            .Complete => return @fromBackingInt(state.completed.?),
            .GrowFrames => {
                frames = try grow(u64, graph.scratch, &workspace.extra_frames, frames, @intCast(state.depth * 2), 2);
                state.frame_capacity = frames.len;
                state.route = .Search;
            },
            .GrowValues => {
                values = try grow(u32, graph.scratch, &workspace.extra_values, values, @intCast(state.used), 1);
                state.value_capacity = values.len;
                state.route = .Search;
            },
            else => {
                const members = values[@intCast(state.used)..][0..@intCast(state.count)];
                state.completed = @backingInt(try continueType(graph, rows, state, members));
            },
        }
    }
}

fn grow(comptime T: type, allocator: std.mem.Allocator, storage: *std.ArrayList(T), previous: []const T, used: usize, added: usize) std.mem.Allocator.Error![]T {
    if (storage.capacity == 0) {
        try storage.ensureTotalCapacity(allocator, used + added);

        storage.appendSliceAssumeCapacity(previous[0..used]);
    } else {
        storage.items.len = used;

        try storage.ensureUnusedCapacity(allocator, added);
    }

    return storage.allocatedSlice();
}

fn continueType(graph: *Graph, rows: Nodes.Storage.Slice, state: anytype, members: []const u32) zx.Error!zx.ir.TypeId {
    const generated = @import("generated_rx_continue_type");
    const Input = std.meta.Child(generated.Input);
    const Tables = std.meta.Child(@FieldType(Input, "tables"));
    const Table = std.meta.Child(@FieldType(Tables, "base"));
    const Pending = std.meta.Child(@FieldType(Input, "pending"));

    const names = switch (rows.items(.kind)[state.node]) {
        .Object => Graph.Fields.fromValues(@ptrCast(rows.items(.members)[state.node])).names(),
        else => &.{},
    };

    const base = zx.ir.TypeTable.borrow(Table, graph.types.items.view());
    const empty = zx.ir.TypeTable.borrow(Table, .{});

    const input: Input = .{
        .tables = &.{ .base = &base, .delta = &empty },
        .pending = &@as(Pending, .{
            .route = @fromBackingInt(@backingInt(state.route)),
            .child = state.completed orelse 0,
            .members = members,
            .names = names,
        }),
    };

    var overflow = std.heap.ArenaAllocator.init(graph.scratch);

    defer overflow.deinit();

    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, overflow.allocator());

    const result = zx.columns.invoke(generated.executeValue, scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (result.graph_issue) {
        const code = std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), result.diagnostic.code) orelse unreachable;

        return graph.reporter.fail(code, rows.items(.span)[state.node], result.diagnostic.message);
    }

    return @import("frontend").commitTypeConstruction(&graph.types, result, .{ .start = 0, .end = 0 }, false);
}
