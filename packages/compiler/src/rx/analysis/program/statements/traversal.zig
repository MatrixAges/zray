const std = @import("std");
const zx = @import("zx");
const Statements = @import("../statements.zig");
const Flow = @import("../flow.zig");
const Writer = @import("../control/writer.zig");
const execution = @import("../../project/workflow/execute.zig");
const host_api = @import("traversal/host.zig");
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_execute_statements") else void;
pub const Input = if (generated) std.meta.Child(rule.Input) else void;
const Output = if (generated) rule.Output else void;

pub fn lower(self: *const Statements, allocator: std.mem.Allocator, root_writer: *Writer.Cursor) Statements.Error!zx.ir.BlockId {
    if (comptime !generated) {
        try @import("traversal/seed.zig").lower(self, allocator, root_writer);
        if (self.plan.implicit_return) self.writer.result(root_writer, null);

        return self.writer.finishBlock(root_writer, self.plan.rows[self.plan.root()].tag, &self.plan.size);
    }

    const Shape = std.meta.Child(@FieldType(Input, "shape"));
    const Steps = std.meta.Child(@FieldType(Shape, "steps"));
    const flow = self.flow;
    const steps = flow.steps.slice();
    const cases = flow.cases.slice();
    const units = flow.units.slice();
    const layout = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(self.plan.rows));
    const root = self.plan.root();

    var state: host_api.State = .{
        .statements = self,
        .allocator = allocator,
        .root = root,
        .root_writer = root_writer,
    };

    state.initControl(layout);

    const binding_slots: zx.memory.ColumnLengths = &.{&self.builder.bindings.items.len};

    var scopes: std.meta.Child(@FieldType(Input, "scopes")) = .{
        .active = @ptrCast(&binding_slots),
        .bindings = &.{},
        .values = &.{},
    };

    var input: Input = .{
        .control = &state.control,
        .scopes = &scopes,
        .root = root,
        .expected = std.mem.bytesAsSlice(u32, std.mem.asBytes(&self.plan.size)),
        .implicit_return = self.plan.implicit_return,
        .started = false,
        .events = &.{},
        .row = 0,
        .offset = 0,
        .shape = &.{
            .steps = &.{
                .kinds = zx.columns.slice(@FieldType(Steps, "kinds"), @as([]const Flow.Kind, steps.items(.kind))),
                .outputs = zx.columns.slice(@FieldType(Steps, "outputs"), @as([]const Flow.Publish, steps.items(.output))),
                .firsts = steps.items(.first),
                .counts = steps.items(.count),
                .exhaustive = steps.items(.exhaustive),
            },
            .units = &.{
                .firsts = units.items(.first),
                .counts = units.items(.count),
                .blocks = units.items(.block),
            },
            .cases = cases.items(.body),
        },
        .layout = layout,
        .borrow_root = self.retain_metadata,
    };

    const bindings = self.builder.bindings.items.len;

    errdefer self.restoreBindings(bindings);

    const Store = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));

    const Host = struct {
        state: *host_api.State,
        reply: *std.meta.Child(Store),
        store_0: *Store,
        pub fn commit(host: *@This(), pending: rule.zx_pending) Statements.Error!void {
            const effect = pending.store_0 orelse return;

            try host_api.apply(host.state, effect, host.reply);
        }
    };

    var reply = execution.snapshot(std.meta.Child(Store), .{
        .step = .Reserve,
        .id = 0,
        .explicit_input = false,
        .addition = false,
        .needs_initializers = false,
    });

    var store: Store = &reply;
    var host: Host = .{ .state = &state, .reply = &reply, .store_0 = &store };

    input.events = (try execute(allocator, &input, &host)).events.?;
    scopes.bindings = state.scope_counts;
    scopes.values = state.scope_values;
    input.started = true;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();

    var bytes: [4096]u8 = undefined;

    while (true) {
        var scratch = std.heap.BufferFirstAllocator.init(&bytes, arena.allocator());
        const output = try execute(scratch.allocator(), &input, &host);

        if (output.block) |block| return @fromBackingInt(block);

        const next = output.next.?;

        try state.commit(next.effect);

        input.row = next.row;
        input.offset = next.offset;
        input.implicit_return = next.implicit_return;
        _ = arena.reset(.retain_capacity);
    }
}

fn execute(allocator: std.mem.Allocator, input: *const Input, host: anytype) Statements.Error!Output {
    return rule.executeIn(allocator, input, host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        error.UnreachableFlow => error.UnreachableFlow,
        error.IncompleteFlow => error.IncompleteFlow,
        else => error.InvalidModule,
    };
}
