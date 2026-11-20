const std = @import("std");
const builtin = @import("builtin");
const zx = @import("zx");
const generated = @import("generated_uniqueness_flow_key");
const Flow = @import("../flow.zig");
const Input = std.meta.Child(generated.Input);

pub fn build(flow: Flow, callees: []const u32, types: *const [32]u8, content: *const [32]u8) [32]u8 {
    var hash: zx.Sha256 = undefined;
    const hash_state = zx.Sha256State{ .value = &hash };

    const input: Input = .{
        .hash = @ptrCast(&hash_state),
        .types = types,
        .content = content,
        .call_functions = callees,
        .held = @ptrCast(flow.held),
        .text_held = @ptrCast(flow.text_held),
        .written = @ptrCast(flow.written),
        .little_endian = builtin.cpu.arch.endian() == .little,
    };

    var memory = std.heap.FixedBufferAllocator.init(&.{});

    generated.executeIn(memory.allocator(), &input) catch |err| std.debug.panic("flow key failed: {s}", .{@errorName(err)});

    return hash.finalResult();
}
