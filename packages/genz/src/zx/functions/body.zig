const std = @import("std");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const stores = @import("../store/transaction.zig");
const signature = @import("../signature/build.zig");
const prelude = @import("prelude/build.zig");
const evaluation = @import("../expressions/evaluate.zig");
const packSpan = @import("../construction/publication.zig").packSpan;
const Error = Lower.Error;

const Frame = struct {
    lowering: *Lower,
    signature_request: signature.Request,
    flags: prelude.Flags = undefined,
    declaration: node.Function = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn lower(self: *Lower, name: []const u8, exported: bool) Error!node.Declaration {
    const entry = @import("generated_lower_function_body");

    var frame: Frame = .{
        .lowering = self,
        .signature_request = .{ .name = name, .exported = exported, .errors = undefined },
    };

    const input: std.meta.Child(entry.Input) = .{
        .body = @ptrCast(&frame),
        .writer = @ptrCast(self),
        .stores = self.program.stores.count() != 0,
    };

    try evaluation.executeWith(self, entry, &input);

    return .{ .function = frame.declaration };
}

pub fn prepareFunctionBody(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    frame.signature_request.errors = try @import("../error_effects.zig").program(self);
    frame.flags = .{ .exported = frame.signature_request.exported, .io = self.entry_flags.io, .process = self.entry_flags.process };

    try @import("context.zig").prepare(self, frame.signature_request.errors);
}

pub fn lowerFunctionStatements(handle: *anyopaque) Error!u64 {
    const self = Frame.borrow(handle).lowering;

    return packSpan(try self.statements(self.program.body.block()));
}

pub fn lowerFunctionContracts(handle: *anyopaque) Error!u64 {
    return packSpan(try @import("../contracts.zig").preconditions(Frame.borrow(handle).lowering));
}

pub fn lowerFunctionPrelude(handle: *anyopaque) Error!u64 {
    const frame = Frame.borrow(handle);

    return packSpan(try prelude.lower(frame.lowering, frame.flags));
}

pub fn lowerFunctionPending(handle: *anyopaque) Error!u64 {
    return packSpan(try stores.initialize(Frame.borrow(handle).lowering));
}

pub fn lowerFunctionReferences(handle: *anyopaque) Error!u64 {
    return packSpan(try Frame.borrow(handle).lowering.referenceBlock());
}

pub fn lowerFunctionCommit(handle: *anyopaque) Error!u64 {
    return packSpan(try stores.finish(Frame.borrow(handle).lowering));
}

pub fn publishFunctionBody(handle: *anyopaque, start: u32, count: u32) Error!void {
    const frame = Frame.borrow(handle);
    var declaration = try signature.build(frame.lowering, &frame.signature_request);

    declaration.body = .{ .start = start, .len = count };
    frame.declaration = declaration;
}
