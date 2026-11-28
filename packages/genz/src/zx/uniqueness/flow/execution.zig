const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Flow = @import("../flow.zig");
const Slots = @import("../slots.zig");
const Memo = @import("../memo.zig");
const entry = @import("generated_uniqueness_flow_solve");
const Fixpoint = @import("fixpoint.zig");
const Error = std.mem.Allocator.Error;
const Store = std.meta.Child(@FieldType(entry.zx_pending, "store_0"));
const Exchange = std.meta.Child(Store);

const Request = struct {
    allocator: std.mem.Allocator,
    workspace: std.mem.Allocator,
    temporary: std.mem.Allocator,
    program: *const ir.Program,
    slots: Slots,
    texts: []const bool,
    contents: []const Memo.Digest,
    types: Memo.Digest,
    memo: ?*Memo,
};

const Frame = struct {
    request: Request,
    recursive: ?Fixpoint = null,
    result: Flow = undefined,
    remembered: ?Flow.Remembered = null,
    walkers: []Flow.Walker = &.{},
};

const Host = struct {
    frame: *Frame,
    temporary: std.mem.Allocator,
    store_0: *Store,
    pub fn commit(host: *Host, pending: anytype) Error!void {
        const exchange = pending.store_0 orelse return;
        const effect = exchange.request.?;
        const frame = host.frame;
        const input = &frame.request;

        const reply = switch (effect.step) {
            .Initialize, .OpenWorkers, .Visit => try host.temporary.create(Exchange),
            else => null,
        };

        var next = exchange.*;

        switch (effect.step) {
            .Initialize => {
                frame.result = try @import("initial.zig").create(input.allocator, input.program.*, input.slots, input.texts);
                next.held = frame.result.held;
            },
            .ReserveMemo => frame.remembered = try Flow.Remembered.init(input.temporary, input.memo.?, input.types, input.contents, input.program.functions.count()),
            .OpenWorkers => {
                frame.walkers = try Flow.Walker.open();
                next.hits = if (frame.remembered) |saved| saved.found else &.{};
            },
            .SolveLayer => try solveLayer(frame, effect.order.?, effect.first.?, effect.end.?),
            .KeepMemo => {
                const remembered = frame.remembered.?;

                remembered.memo.keepFlowed(remembered.keys[@intCast(effect.row.?)]);
            },
            .PublishMemo => try publishMemo(frame, effect.row.?),
            .OpenRecursive => frame.recursive = try Fixpoint.open(frame.result, input.temporary, input.workspace, &input.program.functions, input.slots),
            .RetainFacts => try frame.recursive.?.retain(effect.index.?),
            .Visit => next.changed = try frame.recursive.?.visit(effect.index.?, effect.retained.?),
        }

        if (reply) |saved| {
            saved.* = next;
            host.store_0.* = saved;
        } else {
            host.store_0.* = exchange;
        }
    }
};

pub fn solve(request: Request) Error!Flow {
    var scratch = std.heap.ArenaAllocator.init(request.workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    var frame: Frame = .{ .request = request };
    var store: Store = &.{ .request = null, .held = &.{}, .hits = &.{}, .changed = false };
    var host: Host = .{ .frame = &frame, .temporary = temporary, .store_0 = &store };

    defer Flow.Walker.close(frame.walkers);
    defer if (frame.recursive) |*recursive| recursive.deinit();

    const Input = std.meta.Child(entry.Input);
    const Functions = std.meta.Child(@FieldType(Input, "functions"));
    const functions = &request.program.functions;

    const input: Input = .{
        .functions = &.{
            .native_modules = functions.native_modules,
            .expressions = zx.columns.slice(@FieldType(Functions, "expressions"), functions.expressions),
        },
        .remembered = request.memo != null,
    };

    entry.executeIn(temporary, &input, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    return frame.result;
}

fn solveLayer(frame: *Frame, order: []const u32, first: u64, end: u64) Error!void {
    const input = &frame.request;

    var layer: Flow.Layer = .{
        .flow = frame.result,
        .table = &input.program.functions,
        .slots = input.slots,
        .functions = order[@intCast(first)..@intCast(end)],
        .walkers = frame.walkers,
        .remembered = frame.remembered,
    };

    try layer.spread();
}

fn publishMemo(frame: *const Frame, row: u64) Error!void {
    const kept = frame.remembered.?;
    const flow = &frame.result;
    const index: usize = @intCast(row);

    try kept.memo.putFlowed(kept.keys[index], flow.held[index], flow.text_held[index], flow.written[index]);
}
