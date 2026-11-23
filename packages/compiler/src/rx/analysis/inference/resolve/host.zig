const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Workspace = @import("../resolve.zig").Workspace;

const Frame = struct {
    graph: *Graph,
    rows: Nodes.Storage.Slice,
    workspace: *Workspace,
    frames: []u64,
    values: []u32,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(graph: *Graph, rows: Nodes.Storage.Slice, root: u32, workspace: *Workspace) zx.Error!zx.ir.TypeId {
    const rule = @import("generated_rx_resolve_type");
    const Input = std.meta.Child(rule.Input);
    const View = std.meta.Child(@FieldType(Input, "graph"));
    const kinds: []const Nodes.Kind = rows.items(.kind);
    const arguments = rows.items(.argument);
    const kind_bytes = std.mem.sliceAsBytes(rows.items(.kind));
    const revision: []u64 = (&graph.object_revision)[0..1];
    const parents = graph.parents();

    comptime {
        if (@sizeOf(Nodes.Kind) != @sizeOf(u8)) @compileError("inference kind column must store one byte per row");
    }

    var frame: Frame = .{
        .graph = graph,
        .rows = rows,
        .workspace = workspace,
        .frames = if (workspace.extra_frames.capacity == 0) &workspace.local_frames else workspace.extra_frames.allocatedSlice(),
        .values = if (workspace.extra_values.capacity == 0) &workspace.local_values else workspace.extra_values.allocatedSlice(),
    };

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .graph = &.{
            .kinds = zx.columns.slice(@FieldType(View, "kinds"), kinds),
            .arguments = arguments,
            .members = rows.items(.members),
            .allowed = rows.items(.allowed),
            .fallback = rows.items(.fallback),
        },
        .publication = &.{
            .kinds = @ptrCast(&kind_bytes),
            .arguments = @ptrCast(&arguments),
            .revision = @ptrCast(&revision),
            .known_kind = @backingInt(Nodes.Kind.Known),
        },
        .parents = @ptrCast(&parents),
        .frames = @ptrCast(&frame.frames),
        .values = @ptrCast(&frame.values),
        .frame_capacity = frame.frames.len,
        .value_capacity = frame.values.len,
        .depth = 0,
        .used = 0,
        .count = 0,
        .node = root,
        .completed = null,
        .route = .Search,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const result = rule.executeIn(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        error.InvalidSource => return error.InvalidSource,
        else => unreachable,
    };

    return @fromBackingInt(result.?);
}

pub fn reserveResolveFrames(handle: *const anyopaque, used: u64, added: u64) std.mem.Allocator.Error!u64 {
    const frame = Frame.borrow(handle);

    frame.frames = try grow(u64, frame.graph.scratch, &frame.workspace.extra_frames, frame.frames, @intCast(used), @intCast(added));

    return frame.frames.len;
}

pub fn reserveResolveValues(handle: *const anyopaque, used: u64, added: u64) std.mem.Allocator.Error!u64 {
    const frame = Frame.borrow(handle);

    frame.values = try grow(u32, frame.graph.scratch, &frame.workspace.extra_values, frame.values, @intCast(used), @intCast(added));

    return frame.values.len;
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

pub fn reportResolveFailure(handle: *const anyopaque, node: u32, code: []const u8, message: []const u8) zx.Error!void {
    const frame = Frame.borrow(handle);
    const tag = std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), code) orelse unreachable;

    return frame.graph.reporter.fail(tag, frame.rows.items(.span)[node], message);
}

pub fn constructResolvedType(handle: *const anyopaque, node: u32, child: u32, first: u64, count: u64) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const rows = frame.rows;
    const rule = @import("generated_rx_continue_type");
    const Input = std.meta.Child(rule.Input);
    const Tables = std.meta.Child(@FieldType(Input, "tables"));
    const Table = std.meta.Child(@FieldType(Tables, "base"));
    const Pending = std.meta.Child(@FieldType(Input, "pending"));
    const kind = rows.items(.kind)[node];
    const names = if (kind == .Object) Graph.Fields.fromValues(@ptrCast(rows.items(.members)[node])).names() else &.{};
    const members = frame.values[@intCast(first)..][0..@intCast(count)];
    const base = zx.ir.TypeTable.borrow(Table, graph.types.items.view());
    const empty = zx.ir.TypeTable.borrow(Table, .{});

    const input: Input = .{
        .tables = &.{ .base = &base, .delta = &empty },
        .pending = &@as(Pending, .{
            .kind = kind,
            .child = child,
            .members = members,
            .names = names,
        }),
    };

    var overflow = std.heap.ArenaAllocator.init(graph.scratch);

    defer overflow.deinit();

    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, overflow.allocator());

    const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    return @backingInt(try @import("frontend").commitTypeConstruction(&graph.types, result, .{ .start = 0, .end = 0 }, false));
}
