const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const emit = @import("emitting.zig");
const generated = @import("genz_options").generated_analysis;
const seed = @import("root_seed.zig");

pub fn start(self: *Lower, id: ir.ExprId, concurrent: bool) Lower.Error!node.ExpressionId {
    if (!generated) return seed.start(self, id, concurrent);

    return (try launch(self, id, concurrent, null)).value;
}

pub fn bind(self: *Lower, name: []const u8, id: ir.ExprId, concurrent: bool) Lower.Error!node.Block {
    if (!generated) {
        var storage: [2]node.Statement = undefined;
        var output = std.ArrayList(node.Statement).initBuffer(&storage);

        try seed.bind(self, &output, name, id, concurrent);

        return self.builder.statements(output.items);
    }

    return (try launch(self, id, concurrent, name)).block;
}

fn launch(self: *Lower, id: ir.ExprId, concurrent: bool, name: ?[]const u8) Lower.Error!emit.Started {
    const process = self.entry_flags.body_process;

    self.uses_allocator = true;
    self.uses_io = true;

    if (process) self.uses_process = true;

    const worker = try @import("worker.zig").lower(self, id, process);

    return emit.start(self, worker, id, process, concurrent, name);
}

pub fn wait(self: *Lower, child: ir.ExprId) Lower.Error!node.ExpressionId {
    if (!generated) return seed.wait(self, child);

    return complete(self, child, false);
}

pub fn cancel(self: *Lower, child: ir.ExprId) Lower.Error!node.ExpressionId {
    if (!generated) return seed.cancel(self, child);

    return complete(self, child, true);
}

fn complete(self: *Lower, child: ir.ExprId, canceling: bool) Lower.Error!node.ExpressionId {
    self.uses_io = true;

    const name = try emit.open(self, self.program.expression(child).value == .task);

    if (name) |label| {
        const started = try bind(self, label, child, false);

        return emit.complete(self, started, null, label, canceling);
    }

    return emit.complete(self, .{}, try self.expr(child), null, canceling);
}

pub fn parallel(self: *Lower, type_id: ir.TypeId, branches: @FieldType(@FieldType(ir.ExpressionRow, "value"), "parallel")) Lower.Error!node.ExpressionId {
    if (!generated) return seed.parallel(self, type_id, branches);

    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const futures = try temporary.alloc([]const u8, branches.len);
    var body = self.builder.statementSequence(temporary);

    for (branches.tasks[0..branches.len], futures) |task, *future| {
        future.* = (try emit.open(self, true)).?;

        try body.append(try bind(self, future.*, @fromBackingInt(task), true));
    }

    const completed = try @import("parallel.zig").complete(self, type_id, futures, branches.fields[0..branches.len], temporary);

    try body.append(completed.block);

    return @import("../aggregate.zig").finishStored(self, try body.finish(self.allocator), completed.value, null);
}
