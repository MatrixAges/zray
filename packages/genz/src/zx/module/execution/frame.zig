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

pub const Function = struct { id: ir.FunctionId, definition: ir.Function };

lowering: *Lower,
output: publication.Output,
suffix: publication.Output,
comparisons: std.ArrayList(ir.TypeId) = .empty,
tasks: Auxiliary,
requests: ?*RequestsFrame = null,

function: ?*const Function = null,
result: Stored = undefined,
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

pub fn borrow(handle: *const anyopaque) *Self {
    return @ptrCast(@alignCast(@constCast(handle)));
}

pub fn deinit(self: *Self) void {
    if (generated) {
        self.output.deinit();
        self.suffix.deinit();
    }
}

pub fn finishSeed(self: *Self, type_only: bool) Lower.Error!Stored {
    const lowering = self.lowering;

    if (type_only) return publication.finish(&self.output, lowering.builder.nodes, lowering.allocator);

    return self.tasks.assembleSeed(lowering.allocator, lowering.builder.nodes, &self.output, &self.suffix);
}

pub fn appendModuleAuxiliary(handle: *const anyopaque) Lower.Error!void {
    const frame = borrow(handle);
    const lowering = frame.lowering;

    try frame.output.spans.append(try frame.tasks.store(lowering.allocator, lowering.builder.nodes));
}

pub fn appendModuleSuffix(handle: *const anyopaque) Lower.Error!void {
    const frame = borrow(handle);

    try frame.output.spans.extend(&frame.suffix.spans);
}

pub fn finishModuleDeclarations(handle: *const anyopaque) Lower.Error!void {
    const frame = borrow(handle);
    const lowering = frame.lowering;

    frame.result = try frame.output.spans.finish(lowering.allocator);
}
