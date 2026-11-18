const std = @import("std");
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_prepare_sequence") else void;
const Form = if (generated) rule.Input else enum { Module, Call };

const Step = if (generated) std.meta.Child(rule.Output) else enum {
    BeginModule,
    ResolveStores,
    PrepareBody,
    ImportTypes,
    PublishModule,
    ScanCall,
    ParseArgument,
    AuthorizeCall,
    ResolveCallee,
    PublishCall,
    RecordArgument,
    BindPrevious,
};

pub fn steps(comptime form: Form) []const Step {
    if (comptime !generated) return switch (form) {
        .Module => &.{ .BeginModule, .ResolveStores, .PrepareBody, .ImportTypes, .PublishModule },
        .Call => &.{ .ScanCall, .ParseArgument, .AuthorizeCall, .ResolveCallee, .PublishCall, .RecordArgument, .BindPrevious },
    };

    return &struct {
        const order = blk: {
            var storage: [@typeInfo(Step).@"enum".field_names.len * @sizeOf(Step)]u8 = undefined;
            var scratch = std.heap.FixedBufferAllocator.init(&storage);
            const sequence = rule.executeValue(scratch.allocator(), form) catch unreachable;

            break :blk sequence[0..sequence.len].*;
        };
    }.order;
}
