const std = @import("std");
const zx = @import("zx");
const generated = @import("rx_options").generated_graph;
const rule = if (generated) @import("generated_rx_call_availability") else void;

const Input = if (generated) std.meta.Child(rule.Input) else struct {
    source: bool,
    check_authority: bool,
    declared_setter: bool,
    setter: bool,
    ambient_store: bool,
};

const Result = struct { local: bool, authorized: bool };

pub fn check(input: Input) Result {
    if (comptime !generated) {
        return .{
            .local = input.source and !input.setter,
            .authorized = !input.check_authority or (input.declared_setter == input.setter and !input.ambient_store),
        };
    }

    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

    return .{ .local = result.local, .authorized = result.authorized };
}
