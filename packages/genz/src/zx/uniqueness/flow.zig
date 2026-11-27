const std = @import("std");
const ir = @import("zx").ir;
const Slots = @import("slots.zig");
const Memo = @import("memo.zig");
const Self = @This();
const generated_analysis = @import("genz_options").generated_analysis;
const Seed = @import("flow/seed.zig");
const Body = if (generated_analysis) @import("flow/body.zig") else Seed.Body;
const Walk = if (generated_analysis) @import("flow/walk.zig") else Seed.Walk;

/// Which input slots of each function its output may hold and its updates may write in place, closed over the call
/// graph. A value is followed back from where it ends up to the input slots it can come from: through projections,
/// aggregates, bindings, loop state and the inputs of callees that hold them. What an output holds includes the lists
/// stored as elements of its lists; what an update writes is one buffer, and elements are never written in place. A
/// value whose origin the walk cannot follow counts as every input slot.
held: []const []const bool,
text_held: []const []const bool,
written: []const []const bool,
mutable: struct { held: [][]bool, text_held: [][]bool, written: [][]bool },
/// `memo` keeps the summaries of each body by its `contents` and its callees' summaries, so a later program walks only
/// the bodies whose content or callees changed.
pub fn create(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, slots: Slots, texts: []const bool, contents: []const [32]u8, types: [32]u8, memo: ?*Memo) std.mem.Allocator.Error!Self {
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();

    if (generated_analysis) return @import("flow/execution.zig").solve(.{
        .allocator = allocator,
        .workspace = workspace,
        .temporary = temporary,
        .program = &program,
        .slots = slots,
        .texts = texts,
        .contents = contents,
        .types = types,
        .memo = memo,
    });

    const self = try @import("flow/initial.zig").create(allocator, program, slots, texts);

    if (try @import("flow/layers/root.zig").build(temporary, &program.functions, self.held, memo != null)) |found| {
        const remembered = if (memo) |value|
            try Remembered.init(temporary, value, types, contents, program.functions.count())
        else
            null;

        try self.layeredSeed(&program.functions, slots, found, remembered);
    } else try self.settleSeed(temporary, program, slots);

    return self;
}

pub const Layers = @import("flow/layers/root.zig").Plan;

/// What looking bodies up in a memo needs: the digests of the types and of each body, and per body its key and whether
/// the memo held it.
pub const Remembered = struct {
    memo: *Memo,
    types: [32]u8,
    contents: []const [32]u8,
    keys: []Memo.Digest,
    found: []bool,
    pub fn init(allocator: std.mem.Allocator, memo: *Memo, types: [32]u8, contents: []const [32]u8, count: usize) std.mem.Allocator.Error!Remembered {
        return .{
            .memo = memo,
            .types = types,
            .contents = contents,
            .keys = try allocator.alloc(Memo.Digest, count),
            .found = try allocator.alloc(bool, count),
        };
    }

    /// The key of a body: its content within the types, and the summaries of each function it calls.
    fn key(self: Remembered, flow: Self, expressions: *const ir.ExpressionTable, index: usize) Memo.Digest {
        if (generated_analysis) return @import("flow/key.zig").build(flow, expressions.call_functions, &self.types, &self.contents[index]);

        var hash = @import("zx").Sha256.init(.{});
        var result: Memo.Digest = undefined;

        hash.update("zxc.uniqueness.flow.v5");
        hash.update(&self.types);
        hash.update(&self.contents[index]);

        for (expressions.kinds, 0..) |_, expression| {
            const callee = @backingInt(expressions.callee(expression) orelse continue);

            hash.update(std.mem.asBytes(&@as(u32, @intCast(flow.held[callee].len))));
            hash.update(std.mem.sliceAsBytes(flow.held[callee]));
            hash.update(std.mem.asBytes(&@as(u32, @intCast(flow.text_held[callee].len))));
            hash.update(std.mem.sliceAsBytes(flow.text_held[callee]));
            hash.update(std.mem.sliceAsBytes(flow.written[callee]));
        }

        hash.final(&result);

        return result;
    }
};

fn layeredSeed(self: Self, functions: *const ir.FunctionTable, slots: Slots, found: Layers, remembered: ?Remembered) std.mem.Allocator.Error!void {
    if (found.order.len == 0) return;

    const walkers = try Walker.open();

    defer Walker.close(walkers);

    var start: usize = 0;

    for (found.ends) |boundary| {
        const end: usize = @intCast(boundary);

        if (start == end) continue;

        var layer = Layer{ .flow = self, .table = functions, .slots = slots, .functions = found.order[start..end], .walkers = walkers, .remembered = remembered };

        start = end;

        try layer.spread();

        const kept = remembered orelse continue;

        for (layer.functions) |index| {
            if (functions.native_modules[index] != null) continue;
            if (kept.found[index]) kept.memo.keepFlowed(kept.keys[index]) else try kept.memo.putFlowed(kept.keys[index], self.held[index], self.text_held[index], self.written[index]);
        }
    }
}

pub const Walker = struct {
    bodies: if (generated_analysis) void else std.heap.ArenaAllocator,
    lasting: std.heap.ArenaAllocator,
    walk: ?Walk = null,
    pub fn open() std.mem.Allocator.Error![]Walker {
        const allocator = std.heap.page_allocator;
        const walkers = try allocator.alloc(Walker, @import("zx").parallel.width());

        for (walkers) |*walker| walker.* = .{
            .bodies = if (generated_analysis) {} else .init(allocator),
            .lasting = .init(allocator),
        };

        return walkers;
    }

    pub fn close(walkers: []Walker) void {
        for (walkers) |*walker| {
            if (walker.walk) |*walk| walk.deinit();
            if (!generated_analysis) walker.bodies.deinit();

            walker.lasting.deinit();
        }

        std.heap.page_allocator.free(walkers);
    }
};

/// Walks the bodies of one layer, each participant with its own arenas.
pub const Layer = struct {
    flow: Self,
    table: *const ir.FunctionTable,
    slots: Slots,
    functions: []const u32,
    walkers: []Walker,
    remembered: ?Remembered,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    const Participant = struct {
        layer: *Layer,
        walk: *Walk,
        fn borrow(handle: *const anyopaque) *const Participant {
            return @ptrCast(@alignCast(handle));
        }
    };
    pub fn spread(self: *Layer) std.mem.Allocator.Error!void {
        @import("zx").parallel.spread(Layer, self, run, @min(self.walkers.len, self.functions.len));

        if (self.failed.load(.monotonic)) return error.OutOfMemory;
    }
    fn claim(self: *Layer) ?u32 {
        const position = self.next.fetchAdd(1, .monotonic);

        return if (position < self.functions.len) self.functions[position] else null;
    }
    fn run(self: *Layer, participant: usize) void {
        const walker = &self.walkers[participant];

        if (walker.walk == null) walker.walk = .{ .allocator = walker.lasting.allocator(), .flow = self.flow, .slots = self.slots };

        if (generated_analysis) {
            const entry = @import("generated_uniqueness_flow_worker");
            const selected: Participant = .{ .layer = self, .walk = &walker.walk.? };

            const input: std.meta.Child(entry.Input) = .{
                .worker = @ptrCast(&selected),
                .remembered = self.remembered != null,
                .held = self.flow.held,
            };

            @import("../expressions/evaluate.zig").execute(entry, &input) catch self.failed.store(true, .monotonic);

            return;
        }

        while (self.claim()) |index| {
            self.stepSeed(walker, index) catch {
                self.failed.store(true, .monotonic);

                return;
            };
        }
    }
    fn stepSeed(self: *Layer, walker: *Walker, index: u32) std.mem.Allocator.Error!void {
        if (self.table.native_modules[index] != null) return;

        if (self.remembered) |kept| {
            const key = kept.key(self.flow, self.table.expressions[index], index);

            kept.keys[index] = key;

            kept.found[index] = if (kept.memo.getFlowed(key)) |value|
                Seed.adopt(self.flow, index, value)

            else
                false;

            if (kept.found[index]) return;
        }

        if (self.flow.held[index].len == 0) return;

        const function = self.table.at(index);
        defer _ = walker.bodies.reset(.retain_capacity);
        const body = try Body.create(walker.bodies.allocator(), function, self.slots);
        const walk = &walker.walk.?;

        _ = try walk.analyze(index, &body, self.flow.mutable.held[index], self.flow.mutable.text_held[index], self.flow.mutable.written[index]);
    }
};

pub fn claimFlowBody(handle: *const anyopaque) ?u32 {
    return Layer.Participant.borrow(handle).layer.claim();
}

pub fn adoptFlowMemo(handle: *const anyopaque, index: u32) bool {
    const worker = Layer.Participant.borrow(handle);
    const layer = worker.layer;
    const remembered = layer.remembered.?;
    const key = remembered.key(layer.flow, layer.table.expressions[index], index);
    remembered.keys[index] = key;
    const adopted = if (remembered.memo.getFlowed(key)) |value| worker.walk.adopt(index, value) else false;

    remembered.found[index] = adopted;

    return adopted;
}

pub fn walkFlowBody(handle: *const anyopaque, index: u32) std.mem.Allocator.Error!void {
    const worker = Layer.Participant.borrow(handle);
    _ = try worker.walk.visit(index, Body.View.at(worker.layer.table, index), null);
}

/// Settles summaries over a call graph with cycles: a body is walked again whenever a callee's summary grows.
fn settleSeed(self: Self, allocator: std.mem.Allocator, program: ir.Program, slots: Slots) std.mem.Allocator.Error!void {
    const count = program.functions.count();
    const bodies = try allocator.alloc(?Body, count);
    const callers = try allocator.alloc(std.ArrayList(u32), count);

    for (callers) |*list| list.* = .empty;

    for (0..count) |index| {
        const function = program.functions.at(index);

        bodies[index] = if (function.external == null and self.held[index].len != 0) try Body.create(allocator, function, slots) else null;

        if (bodies[index] == null) continue;

        for (function.expressions.kinds, 0..) |_, expression| {
            const callee = function.expressions.callee(expression) orelse continue;

            try callers[@backingInt(callee)].append(allocator, @intCast(index));
        }
    }

    var queued = try allocator.alloc(bool, count);
    var queue: std.ArrayList(u32) = .empty;

    // Callees come before their callers in the table, and the queue pops from its end, so it starts with the first
    // function on top: most bodies then read finished callee summaries and are walked once.
    for (0..count) |position| {
        const index = count - 1 - position;

        queued[index] = bodies[index] != null;

        if (queued[index]) try queue.append(allocator, @intCast(index));
    }

    var walk = Walk{ .allocator = allocator, .flow = self, .slots = slots };

    defer walk.deinit();

    while (queue.pop()) |index| {
        queued[index] = false;
        const body = &bodies[index].?;
        const text_held = self.mutable.text_held[index];

        if (!try walk.analyze(index, body, self.mutable.held[index], text_held, self.mutable.written[index])) continue;

        for (callers[index].items) |caller| {
            if (queued[caller]) continue;

            queued[caller] = true;

            try queue.append(allocator, caller);
        }
    }
}
