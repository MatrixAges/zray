const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../../lower.zig");
const publication = @import("../../../node/declarations.zig");
const Stored = @import("../../../node/stored.zig").Declarations;
const Requests = @import("../../functions/requests.zig");
const Auxiliary = @import("../../auxiliary.zig");
const generated = @import("genz_options").generated_analysis;
const Self = @This();

pub const RequestsFrame = struct {
    queue: Requests,
    current: Requests.Request = undefined,
    selected: Lower = undefined,
};

lowering: *Lower,
output: publication.Output,
suffix: publication.Output,
comparisons: std.ArrayList(ir.TypeId) = .empty,
tasks: Auxiliary,
requests: ?*RequestsFrame = null,

function: ?ir.FunctionId = null,
pub fn init(lowering: *Lower) Self {
    return .{
        .lowering = lowering,
        .output = publication.init(lowering.builder.nodes, lowering.workspace),
        .suffix = publication.init(lowering.builder.nodes, lowering.workspace),
        .tasks = Auxiliary.init(),
    };
}

pub fn install(self: *Self) void {
    const lowering = self.lowering;

    lowering.comparisons = &self.comparisons;
    lowering.task_declarations = &self.tasks;

    if (self.requests) |requests| lowering.function_requests = &requests.queue;
}

pub fn deinit(self: *Self) void {
    if (generated) {
        self.output.deinit();
        self.suffix.deinit();
    }
}

pub fn finish(self: *Self, type_only: bool) Lower.Error!Stored {
    const lowering = self.lowering;

    if (!generated) {
        if (type_only) return publication.finish(&self.output, lowering.builder.nodes, lowering.allocator);

        return self.tasks.assembleSeed(lowering.allocator, lowering.builder.nodes, &self.output, &self.suffix);
    }

    if (!type_only) {
        try self.output.spans.append(try self.tasks.store(lowering.allocator, lowering.builder.nodes));
        try self.output.spans.extend(&self.suffix.spans);
    }

    return self.output.spans.finish(lowering.allocator);
}
