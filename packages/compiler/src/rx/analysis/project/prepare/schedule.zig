const std = @import("std");
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_module_preparation") else void;
const Form = if (generated) rule.Input else enum { Module, Call };

const Step = if (generated) std.meta.Child(rule.Output) else enum {
    Done,
    BeginModule,
    ResolveStores,
    PrepareFlow,
    ImportTypes,
    PublishModule,
    ScanAttributes,
    ParseArgument,
    Authorize,
    ResolveCallee,
    PublishCall,
    RecordArgument,
};

const capacity = 6;

pub fn steps(comptime form: Form) [capacity]Step {
    var steps_buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&steps_buffer);
    const sequence = if (generated) rule.executeValue(scratch.allocator(), form) catch unreachable else seed(form);
    var result: [capacity]Step = @splat(.Done);

    @memcpy(result[0..sequence.len], sequence);

    return result;
}

fn seed(comptime form: Form) []const Step {
    return switch (form) {
        .Module => &.{ .BeginModule, .ResolveStores, .PrepareFlow, .ImportTypes, .PublishModule },
        .Call => &.{ .ScanAttributes, .ParseArgument, .Authorize, .ResolveCallee, .PublishCall, .RecordArgument },
    };
}
