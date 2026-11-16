const std = @import("std");
const zx = @import("zx");
const Self = @This();

body: usize,
action: enum { done, revisit, reject },
pub fn next(program: *const zx.ir.Program, planned: []const u32, changed: []const bool, first: usize) Self {
    if (@import("genz_options").generated_analysis) {
        const entry = @import("generated_uniqueness_shortcut_next");
        const Input = std.meta.Child(entry.Input);

        const input: Input = .{
            .native_modules = program.functions.native_modules,
            .type_only = program.type_only,
            .planned = planned,
            .changed = changed,
            .first = first,
        };

        var scratch = std.heap.FixedBufferAllocator.init(&.{});
        const result = zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch unreachable;

        return .{ .body = @intCast(result.body), .action = switch (result.action) {
            .Done => .done,
            .Revisit => .revisit,
            .Reject => .reject,
        } };
    }

    const native = program.functions.native_modules;

    for (first..native.len + 1) |body| {
        const active = if (body < native.len) native[body] == null else !program.type_only;

        if (!active) continue;
        if (planned[body + 1] - planned[body] != 1) return .{ .body = body, .action = .reject };
        if (changed[body]) return .{ .body = body, .action = .revisit };
    }

    return .{ .body = native.len + 1, .action = .done };
}
