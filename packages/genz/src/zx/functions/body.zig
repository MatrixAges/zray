const std = @import("std");
const node = @import("../../node.zig");
const blocks = @import("../../node/blocks.zig");
const Lower = @import("../lower.zig");
const stores = @import("../store/transaction.zig");
const signature = @import("../signature/build.zig");
const prelude = @import("prelude/build.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Section = evaluation.Api.BodySection;
const Error = Lower.Error;

const Frame = struct {
    lowering: *Lower,
    signature_request: signature.Request,
    sections: std.EnumArray(Section, node.Block) = .initFill(.{}),
    flags: prelude.Flags = undefined,
    declaration: node.Function = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        const reference: *const *Frame = @ptrCast(@alignCast(handle));

        return reference.*;
    }
};

pub fn lower(self: *Lower, name: []const u8, exported: bool) Error!node.Declaration {
    const entry = @import("generated_lower_function_body");

    var frame: Frame = .{
        .lowering = self,
        .signature_request = .{ .name = name, .exported = exported, .errors = undefined },
    };

    const reference = &frame;

    const input: std.meta.Child(entry.Input) = .{
        .body = @ptrCast(&reference),
        .stores = self.program.stores.count() != 0,
    };

    try evaluation.execute(entry, &input);

    return .{ .function = frame.declaration };
}

pub fn prepareFunctionBody(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    frame.signature_request.errors = try @import("../error_effects.zig").program(self);
    frame.flags = .{ .exported = frame.signature_request.exported, .io = self.entry_flags.io, .process = self.entry_flags.process };

    try @import("context.zig").prepare(self, frame.signature_request.errors);
}

pub fn lowerFunctionStatements(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    frame.sections.set(.Statements, try self.statements(self.program.body.block()));
}

pub fn lowerFunctionContracts(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.sections.set(.Contracts, try @import("../contracts.zig").preconditions(frame.lowering));
}

pub fn lowerFunctionPrelude(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.sections.set(.Prelude, try prelude.lower(frame.lowering, frame.flags));
}

pub fn lowerFunctionPending(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.sections.set(.Pending, try stores.initialize(frame.lowering));
}

pub fn lowerFunctionReferences(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.sections.set(.References, try frame.lowering.referenceBlock());
}

pub fn lowerFunctionCommit(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.sections.set(.Commit, try stores.finish(frame.lowering));
}

pub fn publishFunctionBody(handle: *const anyopaque, before: Section, pending: Section, references: Section, contracts: Section, statements: Section, commit: Section) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    var declaration = try signature.build(self, &frame.signature_request);
    const order = [_]Section{ before, pending, references, contracts, statements, commit };
    var starts: [order.len]u32 = undefined;
    var lengths: [order.len]u32 = undefined;

    inline for (order, &starts, &lengths) |section, *start, *length| {
        const block = frame.sections.get(section);
        start.* = block.start;
        length.* = block.len;
    }

    declaration.body = try blocks.join(self.allocator, self.builder.nodes, &starts, &lengths);
    frame.declaration = declaration;
}
