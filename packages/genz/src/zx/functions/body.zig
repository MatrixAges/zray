const std = @import("std");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const stores = @import("../store/transaction.zig");
const prelude = @import("prelude/build.zig");
const borrow = @import("../expressions/evaluate.zig").borrow;
const publication = @import("../construction/publication.zig");
const Error = Lower.Error;

pub fn lower(self: *Lower, name: []const u8, exported: bool) Error!node.Declaration {
    const entry = @import("generated_lower_function_body");

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .name = name,
        .input_id = @backingInt(self.program.input_type),
        .output_id = @backingInt(self.program.output_type),
        .store_count = self.program.stores.count(),
        .exported = exported,
        .inlined = self.entry_flags.inlined,
        .io = self.entry_flags.io,
        .process = self.entry_flags.process,
        .value = self.value_output,
        .public_value = self.public_value_output,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [512]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const body = entry.executeIn(memory.allocator(), &input) catch |err| return publication.failure(err);

    return .{ .function = .{
        .name = body.name,
        .parameters = @import("../../node/import_fields.zig").materializeBorrowingText(self.allocator, body.parameters) catch |err| return publication.failure(err),
        .return_type = @fromBackingInt(body.return_type),
        .body = .{ .start = body.start, .len = body.count },
        .exported = body.exported,
        .inlined = body.inlined,
    } };
}

pub fn prepareFunctionBody(frame: *anyopaque) Error!?[]const []const u8 {
    const self = borrow(frame);
    const errors = try @import("../error_effects.zig").program(self);

    try @import("context.zig").prepare(self, errors);

    return errors;
}

pub fn lowerFunctionStatements(frame: *anyopaque) Error!u64 {
    const self = borrow(frame);

    return publication.packSpan(try self.statements(self.program.body.block()));
}

pub fn lowerFunctionContracts(frame: *anyopaque) Error!u64 {
    return publication.packSpan(try @import("../contracts.zig").preconditions(borrow(frame)));
}

pub fn lowerFunctionPrelude(frame: *anyopaque, exported: bool, io: bool, process: bool) Error!u64 {
    return publication.packSpan(try prelude.lower(borrow(frame), .{ .exported = exported, .io = io, .process = process }));
}

pub fn lowerFunctionPending(frame: *anyopaque) Error!u64 {
    return publication.packSpan(try stores.initialize(borrow(frame)));
}

pub fn lowerFunctionReferences(frame: *anyopaque) Error!u64 {
    return publication.packSpan(try borrow(frame).referenceBlock());
}

pub fn lowerFunctionCommit(frame: *anyopaque) Error!u64 {
    return publication.packSpan(try stores.finish(borrow(frame)));
}
