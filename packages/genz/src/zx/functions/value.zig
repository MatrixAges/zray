const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const policy = @import("policy.zig");
const state = @import("../state_value/root.zig");
const scope = @import("../state_value/scope.zig");
const generated = @import("genz_options").generated_analysis;
const argument: ir.SymbolId = @fromBackingInt(0);
const Error = Lower.Error;
const Step = enum { Enter, Reuse, Bind, Open, Value, Abi, Prototype, Body };

pub fn lower(self: *Lower, name: []const u8, comptime signature: bool) Error!node.Declaration {
    const mode = policy.value(self);

    if (generated) {
        const entry = @import("generated_lower_value_function");

        const input: std.meta.Child(entry.Input) = .{
            .signature = signature,
            .enter = mode.enter,
            .bind_input = mode.bind_input,
            .value_output = mode.value_output,
        };

        var scratch = std.heap.ArenaAllocator.init(self.workspace);
        var buffer: [256]u8 = undefined;
        var allocator = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

        defer scratch.deinit();

        const steps = entry.executeIn(allocator.allocator(), &input) catch |err| return @import("../construction/publication.zig").failure(err);

        return emit(self, name, steps);
    }

    const steps = [_]Step{
        if (mode.enter) .Enter else .Reuse,
        if (mode.bind_input) .Bind else .Open,
        if (mode.value_output) .Value else .Abi,
        if (signature) .Prototype else .Body,
    };

    return emit(self, name, &steps);
}

fn emit(self: *Lower, name: []const u8, steps: anytype) Error!node.Declaration {
    var representation: @typeInfo(@typeInfo(@TypeOf(state.enter)).@"fn".return_type.?).error_union.payload = null;
    var argument_scope = false;
    var output: ?scope.Frame(.Value) = null;

    defer {
        if (output) |saved| saved.restore();
        if (argument_scope) _ = self.state_symbols.remove(argument);
        if (representation) |saved| saved.restore();
    }

    for (steps) |step| switch (step) {
        .Enter => representation = try state.enter(self),
        .Reuse => {},
        .Bind => {
            try self.state_symbols.put(self.allocator, argument, {});

            argument_scope = true;
        },
        .Open => argument_scope = true,
        .Value => output = scope.enter(self, .Value, .{ .value_output = true }),
        .Abi => output = scope.enter(self, .Value, .{ .value_output = false }),
        .Prototype => return .{ .function = try self.prototype(name, false) },
        .Body => return self.function(name, false),
    };

    unreachable;
}
