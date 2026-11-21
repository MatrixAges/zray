const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const policy = @import("policy.zig");
const scope = @import("../state_value/scope.zig");
const generated = @import("genz_options").generated_analysis;
const entry = if (generated) @import("generated_function_value_workflow") else void;
const Step = if (generated) std.meta.Child(entry.Output) else enum { Representation, Argument, Output, Body, Signature };

pub fn lower(self: *Lower, name: []const u8, comptime signature: bool) Lower.Error!node.Declaration {
    const steps: []const Step = comptime if (generated)
        zx.staticSequence(entry, if (signature) .Signature else .Body)

    else
        &.{ .Representation, .Argument, .Output, if (signature) .Signature else .Body };

    return run(self, name, policy.value(self), steps);
}

inline fn run(self: *Lower, name: []const u8, mode: policy.Mode, comptime steps: []const Step) Lower.Error!node.Declaration {
    return switch (steps[0]) {
        .Representation => represented: {
            const state = if (mode.enter) try @import("../state_value/root.zig").enter(self) else null;

            defer if (state) |saved| saved.restore();

            break :represented try run(self, name, mode, steps[1..]);
        },
        .Argument => bound: {
            const argument: zx.ir.SymbolId = @fromBackingInt(0);

            if (mode.bind_input) try self.state_symbols.put(self.allocator, argument, {});

            defer _ = self.state_symbols.remove(argument);

            break :bound try run(self, name, mode, steps[1..]);
        },
        .Output => selected: {
            const output = scope.enter(self, .Value, .{ .value_output = mode.value_output });

            defer output.restore();

            break :selected try run(self, name, mode, steps[1..]);
        },
        .Body => self.function(name, false),
        .Signature => .{ .function = try self.prototype(name, false) },
    };
}
