const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const blocks = @import("../../node/blocks.zig");
const aggregate = @import("../aggregate.zig");
const emit = @import("emitting.zig");
const generated = @import("genz_options").generated_analysis;

pub fn start(self: *Lower, id: ir.ExprId, concurrent: bool) Lower.Error!node.ExpressionId {
    if (!generated) return @import("root_seed.zig").start(self, id, concurrent);

    const captures = self.program.expression(id).value.task.captures;
    const process = self.entry_flags.body_process;

    self.uses_allocator = true;
    self.uses_io = true;

    if (process) self.uses_process = true;

    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const names = try scratch.allocator().alloc([]const u8, captures.len);
    const addresses = try scratch.allocator().alloc(bool, captures.len);

    for (captures, names, addresses) |symbol, *name, *address| {
        self.used[@backingInt(symbol)] = true;

        name.* = self.names[@backingInt(symbol)];
        address.* = self.stack_symbols.contains(symbol);
    }

    const worker = try @import("worker.zig").lower(self, id, process);

    return emit.start(self, worker, process, concurrent, names, addresses);
}

pub fn bind(self: *Lower, name: []const u8, id: ir.ExprId, concurrent: bool) Lower.Error!node.Block {
    if (!generated) {
        var storage: [2]node.Statement = undefined;
        var output = std.ArrayList(node.Statement).initBuffer(&storage);

        try @import("root_seed.zig").bind(self, &output, name, id, concurrent);

        return self.builder.statements(output.items);
    }

    return emit.bind(self, name, try start(self, id, concurrent));
}

pub fn wait(self: *Lower, child: ir.ExprId) Lower.Error!node.ExpressionId {
    if (!generated) return @import("root_seed.zig").wait(self, child);

    self.uses_io = true;

    if (self.program.expression(child).value != .task) return emit.call(self, try self.expr(child), null, .Await, true);

    const name = try emit.fresh(self, .Future);
    const body = try bind(self, name, child, false);
    const value = try emit.call(self, null, name, .Await, true);

    return aggregate.finishStored(self, body, value, null);
}

pub fn parallel(self: *Lower, type_id: ir.TypeId, branches: @FieldType(@FieldType(ir.ExpressionRow, "value"), "parallel")) Lower.Error!node.ExpressionId {
    if (!generated) return @import("root_seed.zig").parallel(self, type_id, branches);

    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const futures = try temporary.alloc([]const u8, branches.len);
    const results = try temporary.alloc([]const u8, branches.len);
    const values = try temporary.alloc(?[]const u8, branches.len);
    const fields = try temporary.alloc(?[]const u8, branches.len);
    var parts: std.MultiArrayList(node.Block) = .empty;

    try parts.ensureTotalCapacity(temporary, std.math.add(usize, branches.len, 2) catch return error.OutOfMemory);

    for (0..branches.len, futures) |index, *name| {
        name.* = try emit.fresh(self, .Future);

        parts.appendAssumeCapacity(try bind(self, name.*, @fromBackingInt(branches.tasks[index]), true));
    }

    for (results) |*name| name.* = try emit.fresh(self, .Result);

    parts.appendAssumeCapacity(try @import("parallel.zig").awaitAll(self, futures, results));

    for (0..branches.len, values, fields) |index, *name, *field| {
        if (branches.at(index).field) |selected| {
            name.* = try emit.fresh(self, .Value);
            field.* = self.program.typeOf(type_id).object.at(selected).name;
        } else {
            name.* = null;
            field.* = null;
        }
    }

    const object = self.program.typeOf(type_id) == .object;
    const result = try @import("parallel.zig").result(self, results, values, fields, object);
    const value = if (object) try self.construct(type_id, result.value) else result.value;

    parts.appendAssumeCapacity(result.block);

    const body = try blocks.tail(self.allocator, self.builder.nodes, parts.items(.start), parts.items(.len));

    return aggregate.finishStored(self, body, value, null);
}

pub fn cancel(self: *Lower, child: ir.ExprId) Lower.Error!node.ExpressionId {
    if (!generated) return @import("root_seed.zig").cancel(self, child);

    self.uses_io = true;
    var started: node.Block = .{};
    var name: ?[]const u8 = null;
    var value: ?node.ExpressionId = null;

    if (self.program.expression(child).value == .task) {
        name = try emit.fresh(self, .Future);
        started = try bind(self, name.?, child, false);
    } else value = try self.expr(child);

    const result = try emit.cancel(self, value, name);
    const body = try blocks.tail(self.allocator, self.builder.nodes, &.{ started.start, result.block.start }, &.{ started.len, result.block.len });

    return aggregate.finishStored(self, body, result.value, null);
}
