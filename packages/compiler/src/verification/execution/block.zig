const std = @import("std");
const zx = @import("zx");
const Conditions = @import("../conditions.zig");
const expression = @import("expression.zig");
const Expressions = @import("../expressions.zig");
const terms = @import("../terms.zig");
const Session = @import("context.zig");
const walk = @import("generated_walk_symbolic_block");
const Input = std.meta.Child(walk.Input);
const Scope = std.meta.Child(@FieldType(Input, "scope"));
const Store = std.meta.Child(@FieldType(walk.zx_pending, "store_0"));
const Exchange = std.meta.Child(Store);
const Result = std.meta.Child(@FieldType(Exchange, "result"));

const Bindings = struct {
    slots: []expression.Binding,
    values: []std.meta.Child(expression.BoundValue),
    fn bind(self: Bindings, symbol: u32, value: terms.Value) void {
        const descriptor = &self.values[symbol];

        descriptor.* = (terms.Evaluation{ .value = value }).descriptor(@TypeOf(descriptor.*));
        self.slots[symbol] = descriptor;
    }
};

const Host = struct {
    conditions: *Conditions,
    scope: *const Scope,
    evaluator: Expressions,
    bindings: Bindings,
    temporary: std.mem.Allocator,
    store_0: *Store,
    pub fn commit(host: *Host, pending: anytype) zx.Error!void {
        const operation = pending.store_0 orelse return;
        const request = operation.request.?;
        const allocator = host.temporary;
        const exchange = try allocator.create(Exchange);
        const result = try allocator.create(Result);

        result.* = operation.result.*;

        switch (request.step) {
            .Evaluate => {
                host.evaluator.environment = zx.columns.slice(expression.Environment, operation.bindings);

                const value: terms.Evaluation = if (request.row) |id|
                    try host.evaluator.evaluate(@fromBackingInt(id))
                else
                    .{ .value = .{} };

                result.value = try value.view(@TypeOf(result.value), allocator);
            },
            .Boolean => result.term = try host.conditions.boolean(request.term.?),
            .Bind => {
                if (request.row) |symbol| {
                    const value = terms.Evaluation.fromView(request.value.?).value;

                    host.bindings.bind(symbol, value);
                }
            },
            .Child, .Return => {
                const path = request.path.?;
                const input: Session.Path = .{ .path = path.path, .violations = path.violations };

                const next = if (request.step == .Child)
                    try host.child(request.row.?, &input)
                else
                    try host.publish(&input, terms.Evaluation.fromView(request.value.?).value);

                const published = try allocator.create(std.meta.Child(@TypeOf(result.path)));
                published.* = .{ .path = next.path, .violations = next.violations };
                result.path = published;
            },
        }

        exchange.* = .{
            .bindings = zx.columns.slice(@FieldType(Exchange, "bindings"), @as(expression.Environment, host.bindings.slots)),
            .request = null,
            .result = result,
        };

        host.store_0.* = exchange;
    }
    fn child(host: *Host, row: u32, path: *const Session.Path) zx.Error!Session.Path {
        const control = host.evaluator.program.body.control;

        return within(
            host.conditions,
            host.scope,
            host.bindings,
            control.block_first[row],
            control.block_count[row],
            path,
        );
    }
    fn publish(host: *Host, path: *const Session.Path, value: terms.Value) zx.Error!Session.Path {
        const conditions = host.conditions;
        const checked = try Session.apply(conditions, .Returned, path, value);

        try conditions.returns.append(conditions.allocator, .{ .path = path.path, .value = value });

        return checked;
    }
};

pub fn execute(conditions: *Conditions, statements: zx.ir.Block, path: []const u8) zx.Error![]const u8 {
    if (statements.len == 0) return path;

    const table: *const zx.ir.ControlTable = statements.control;
    const control = zx.columns.borrow(std.meta.Child(@FieldType(Scope, "control")), table);
    const layout = terms.Value.layout(std.meta.Child(@FieldType(Scope, "layout")));

    const scope: Scope = .{
        .control = &control,
        .layout = &layout,
        .expression_payloads = conditions.program.expressions.payloads,
        .call_arguments = conditions.program.expressions.call_arguments,
    };

    const checkpoint = conditions.scratch.checkpoint();

    defer conditions.scratch.rewindRetainingCapacity(checkpoint);

    const allocator = conditions.scratch.allocator();
    const count = conditions.program.symbols.count();
    const slots = try allocator.alloc(expression.Binding, count);
    const values = try allocator.alloc(std.meta.Child(expression.BoundValue), count);
    const bindings: Bindings = .{ .slots = slots, .values = values };

    @memset(slots, null);
    bindings.bind(0, conditions.input);

    const outcome = try within(conditions, &scope, bindings, statements.first, statements.len, &.{
        .path = path,
        .violations = conditions.violations,
    });

    conditions.violations = outcome.violations;

    return outcome.path;
}

fn within(conditions: *Conditions, scope: *const Scope, bindings: Bindings, first: usize, count: usize, path: *const Session.Path) zx.Error!Session.Path {
    if (count == 0) return path.*;

    const checkpoint = conditions.scratch.checkpoint();

    defer conditions.scratch.rewindRetainingCapacity(checkpoint);

    var effects = zx.Arena.initSmall(conditions.scratch.child);
    var buffer: [2048]u8 = undefined;
    var temporary = std.heap.BufferFirstAllocator.init(&buffer, effects.allocator());

    defer effects.deinit();

    var store: Store = &.{
        .bindings = zx.columns.slice(@FieldType(Exchange, "bindings"), @as(expression.Environment, bindings.slots)),
        .request = null,
        .result = &.{
            .value = &.{ .text = null, .fields = &.{}, .safe = "true" },
            .path = &.{ .path = path.path, .violations = path.violations },
            .term = "",
        },
    };

    var host: Host = .{
        .conditions = conditions,
        .scope = scope,
        .bindings = bindings,
        .evaluator = .{
            .allocator = conditions.allocator,
            .scratch = conditions.scratch,
            .program = conditions.program,
            .environment = &.{},
            .graph = conditions.graph.?,
            .reporter = conditions.reporter,
            .call_depth = conditions.call_depth,
        },
        .temporary = temporary.allocator(),
        .store_0 = &store,
    };

    const input: Input = .{
        .scope = scope,
        .path = path.path,
        .violations = path.violations,
        .first = first,
        .count = count,
    };

    const continuation = walk.executeIn(conditions.allocator, &input, &host) catch |err| return Session.failure(err);

    if (continuation) |next_path| return .{ .path = next_path.path, .violations = next_path.violations };

    return conditions.reporter.fail(.unsupported, .{ .start = 0, .end = 0 }, "verification does not yet model this statement");
}
