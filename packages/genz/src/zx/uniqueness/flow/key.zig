const std = @import("std");
const builtin = @import("builtin");
const generated = @import("generated_uniqueness_flow_key");
const Flow = @import("../flow.zig");
const Input = std.meta.Child(generated.Input);

pub fn build(flow: Flow, callees: []const u32, types: *const [32]u8, content: *const [32]u8) [32]u8 {
    const input: Input = .{
        .types = types,
        .content = content,
        .call_functions = callees,
        .held = @ptrCast(flow.held),
        .text_held = @ptrCast(flow.text_held),
        .written = @ptrCast(flow.written),
        .little_endian = builtin.cpu.arch.endian() == .little,
    };

    var pending: [2048]u8 = undefined;
    var backing = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer backing.deinit();

    var scratch = std.heap.BufferFirstAllocator.init(&pending, backing.allocator());
    const digest = generated.executeIn(scratch.allocator(), &input) catch |err| std.debug.panic("flow key failed: {s}", .{@errorName(err)});

    std.debug.assert(digest.len == 32);

    return digest[0..32].*;
}
