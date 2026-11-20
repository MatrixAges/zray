const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Scope = @import("scope.zig");
const Selection = @import("../switch/state.zig");
const entry = @import("generated_statement_traversal");
const Input = std.meta.Child(entry.Input);
const Rows = std.meta.Child(@FieldType(Input, "rows"));

pub fn lower(self: *Lower, values: ir.Block) Lower.Error!node.Block {
    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var inline_memory: [4096]u8 = undefined;
    var buffer = std.heap.BufferFirstAllocator.init(&inline_memory, arena.allocator());

    defer arena.deinit();

    const scratch = buffer.allocator();
    const rows = zx.columns.borrow(Rows, values.control);
    const input: Input = .{ .rows = &rows, .first = values.first, .count = values.len };
    const plan = zx.columns.invoke(entry.executeValue, scratch, &input) catch |err| return failure(err);
    const capacity: usize = @intCast(plan.capacity);
    const spans = try scratch.alloc(u32, std.math.mul(usize, capacity, 2) catch return error.OutOfMemory);
    const routes = try scratch.alloc(u8, capacity);
    var output: std.ArrayList(node.Statement) = .empty;

    defer output.deinit(self.allocator);

    const workspace: Scope.Buffer = .{
        .starts = spans[0..capacity],
        .counts = spans[capacity..],
        .routes = routes,
    };

    if (plan.flat) {
        const scope = try Scope.open(self, values, workspace);

        defer scope.close(self);

        try scope.run(self, &output, 0, values.len);

        return scope.finish(self);
    }

    const scopes = try scratch.alloc(Scope, @intCast(plan.depth));
    const selections = try scratch.alloc(Selection, @intCast(plan.selection_depth));
    var depth: usize = 0;
    var selection_depth: usize = 0;
    var occupied: usize = 0;
    var child: node.Block = .{};

    errdefer while (depth != 0) {
        depth -= 1;

        scopes[depth].close(self);
    };

    for (plan.actions, plan.offsets, plan.counts) |action, first, count| {
        if (action == .Open) {
            const range: ir.Block = .{ .control = values.control, .first = first, .len = count };

            scopes[depth] = try Scope.open(self, range, .{
                .starts = workspace.starts[occupied..][0..range.len],
                .counts = workspace.counts[occupied..][0..range.len],
                .routes = workspace.routes[occupied..][0..range.len],
            });

            occupied += range.len;
            depth += 1;

            continue;
        }

        const scope = &scopes[depth - 1];

        switch (action) {
            .Open, .Descend => unreachable,
            .Execute => try scope.run(self, &output, first, count),
            .Condition => scope.condition = try self.expr(scope.values.at(first).branch.condition),
            .SaveYes => scope.yes = child,
            .Join => {
                output.clearRetainingCapacity();
                scope.put(first, try @import("../basic.zig").branch(self, &output, scope.condition, scope.yes, child));
            },
            .Selection => {
                const selection = &selections[selection_depth];

                try selection.enter(self, scope.values.at(first).switch_stmt);

                scope.selection = selection;
                selection_depth += 1;
            },
            .Fallback => scope.selection.?.fallback = child,
            .Resolve => try scope.selection.?.resolve(self, count),
            .Case => try scope.selection.?.beforeCase(self, count, @fromBackingInt(first)),
            .SaveCase => try scope.selection.?.afterCase(self, count, @fromBackingInt(first), child),
            .EndSelection => {
                const selection = scope.selection.?;

                scope.put(first, try selection.finish(self));
                selection.leave(self);

                scope.selection = null;
                selection_depth -= 1;
            },
            .Close => {
                child = try scope.finish(self);

                scope.close(self);

                occupied -= scope.values.len;
                depth -= 1;
            },
        }
    }

    return child;
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
