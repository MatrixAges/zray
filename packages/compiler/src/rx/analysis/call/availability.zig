const std = @import("std");
const zx = @import("zx");
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_call_availability") else void;

const Input = if (generated) std.meta.Child(rule.Input) else struct {
    target: enum { Source, Compiled, Native },
    named: bool,
    declared_setter: bool,
    setter: bool,
    ambient_store: bool,
};

const Output = if (generated) @typeInfo(@typeInfo(@TypeOf(rule.executeValue)).@"fn".return_type.?).error_union.payload else struct { route: enum { Source, AuthorizedSource, NamedSource, NamedSetter, NamedTarget, Compiled, Native, Denied }, local: bool };

pub fn check(input: Input) Output {
    if (comptime !generated) {
        const route: @FieldType(Output, "route") = if (input.named)
            if (input.target != .Source) .NamedTarget else if (input.setter) .NamedSetter else .NamedSource

        else switch (input.target) {
            .Source => if (input.setter) .AuthorizedSource else .Source,
            .Compiled => if (input.declared_setter == input.setter and !input.ambient_store) .Compiled else .Denied,
            .Native => .Native,
        };

        return .{ .route = route, .local = route == .Source or route == .NamedSource };
    }

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;
}
