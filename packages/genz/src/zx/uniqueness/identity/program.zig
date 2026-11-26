const std = @import("std");
const zx = @import("zx");
const Basis = @import("../basis.zig");
const generated = @import("generated_uniqueness_program_identity");
const Input = std.meta.Child(generated.Input);

pub fn build(value: zx.ir.Program, basis: *const Basis, return_allocations: []const bool) [32]u8 {
    const input: Input = .{
        .types = &basis.types,
        .input_types = @ptrCast(value.functions.input_types),
        .output_types = @ptrCast(value.functions.output_types),
        .native_modules = value.functions.native_modules,
        .held = @ptrCast(basis.flow.held),
        .written = @ptrCast(basis.flow.written),
        .return_only = std.mem.sliceAsBytes(basis.return_only),
        .return_allocations = std.mem.sliceAsBytes(return_allocations),
    };

    var pending: [4096]u8 = undefined;
    var backing = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer backing.deinit();

    var scratch = std.heap.BufferFirstAllocator.init(&pending, backing.allocator());
    const digest = generated.executeIn(scratch.allocator(), &input) catch |err| std.debug.panic("program identity failed: {s}", .{@errorName(err)});

    std.debug.assert(digest.len == 32);

    return digest[0..32].*;
}
