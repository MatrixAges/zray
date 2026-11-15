const std = @import("std");
const zx = @import("zx");
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_call_availability") else void;

const Input = if (generated) std.meta.Child(rule.Input) else struct {
    target: enum { Source, Compiled, Native },
    declared_setter: bool,
    setter: bool,
    ambient_store: bool,
};

const Route = if (generated) @typeInfo(@typeInfo(@TypeOf(rule.executeValue)).@"fn".return_type.?).error_union.payload else enum { Source, AuthorizedSource, Compiled, Native, Denied };

pub fn check(input: Input) Route {
    if (comptime !generated) {
        return switch (input.target) {
            .Source => if (input.setter) .AuthorizedSource else .Source,
            .Compiled => if (input.declared_setter == input.setter and !input.ambient_store) .Compiled else .Denied,
            .Native => .Native,
        };
    }

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;
}
