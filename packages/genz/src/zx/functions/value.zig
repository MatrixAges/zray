const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const policy = @import("policy.zig");
const state = @import("../state_value/root.zig");
const scope = @import("../state_value/scope.zig");
const generated = @import("genz_options").generated_analysis;
const evaluation = @import("../expressions/evaluate.zig");
const argument: ir.SymbolId = @fromBackingInt(0);
const Representation = @typeInfo(@typeInfo(@TypeOf(state.enter)).@"fn".return_type.?).error_union.payload;
const Error = Lower.Error;

const Frame = struct {
    lowering: *Lower,
    name: []const u8,
    representation: Representation = null,
    argument_scope: bool = false,
    output: ?scope.Frame(.Value) = null,
    declaration: node.Declaration = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
    fn restore(self: *Frame) void {
        if (self.output) |saved| saved.restore();
        if (self.argument_scope) _ = self.lowering.state_symbols.remove(argument);
        if (self.representation) |saved| saved.restore();
    }
};

pub fn lower(self: *Lower, name: []const u8, comptime signature: bool) Error!node.Declaration {
    const mode = policy.value(self);
    var frame: Frame = .{ .lowering = self, .name = name };
    const body: *anyopaque = @ptrCast(&frame);

    defer frame.restore();

    if (generated) {
        const entry = @import("generated_lower_value_function");

        const input: std.meta.Child(entry.Input) = .{
            .body = @ptrCast(&frame),
            .signature = signature,
            .enter = mode.enter,
            .bind_input = mode.bind_input,
            .value_output = mode.value_output,
        };

        try evaluation.execute(entry, &input);
    } else {
        if (mode.enter) try enterFunctionRepresentation(body);
        try bindFunctionArgument(body, mode.bind_input);

        setFunctionOutput(body, mode.value_output);

        if (signature) try emitValuePrototype(body) else try emitValueBody(body);
    }

    return frame.declaration;
}

pub fn enterFunctionRepresentation(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.representation = try state.enter(frame.lowering);
}

pub fn bindFunctionArgument(handle: *anyopaque, bind: bool) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    if (bind) try self.state_symbols.put(self.allocator, argument, {});

    frame.argument_scope = true;
}

pub fn setFunctionOutput(handle: *anyopaque, value: bool) void {
    const frame = Frame.borrow(handle);

    frame.output = scope.enter(frame.lowering, .Value, .{ .value_output = value });
}

pub fn emitValuePrototype(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.declaration = .{ .function = try frame.lowering.prototype(frame.name, false) };
}

pub fn emitValueBody(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.declaration = try frame.lowering.function(frame.name, false);
}
