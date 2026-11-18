const std = @import("std");
const zx = @import("zx");
const Trace = @import("../trace.zig");
const Cursor = @This();

body: usize = 0,
visit: usize = 0,

phase: enum { start, settled, demanded, planned, done, reject } = .start,
pub fn next(self: Cursor, program: *const zx.ir.Program, trace: *const Trace, changed: []const bool) Cursor {
    if (!@import("genz_options").generated_analysis) return self.nextSeed(program, trace, changed);

    const entry = @import("generated_uniqueness_shortcut_advance");
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .native_modules = program.functions.native_modules,
        .type_only = program.type_only,
        .settled = trace.settled.starts,
        .demanded = trace.demanded.starts,
        .planned = trace.planned.starts,
        .changed = changed,
        .cursor = &.{ .body = self.body, .visit = self.visit, .phase = @fromBackingInt(@intCast(@backingInt(self.phase))) },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

    return .{ .body = @intCast(result.body), .visit = @intCast(result.visit), .phase = @fromBackingInt(@intCast(@backingInt(result.phase))) };
}

fn nextSeed(self: Cursor, program: *const zx.ir.Program, trace: *const Trace, changed: []const bool) Cursor {
    var body = self.body;

    if (self.phase == .start or self.phase == .planned) {
        if (self.phase == .planned) body += 1;

        const native = program.functions.native_modules;

        while (body <= native.len) : (body += 1) {
            const active = if (body < native.len) native[body] == null else !program.type_only;

            if (!active) continue;
            if (trace.planned.starts[body + 1] - trace.planned.starts[body] != 1) return .{ .body = body, .phase = .reject };
            if (changed[body]) break;
        }

        if (body > native.len) return .{ .body = body, .phase = .done };
    }

    if (self.phase != .demanded) {
        const visit = if (self.phase == .settled) self.visit + 1 else trace.settled.starts[body];

        if (visit < trace.settled.starts[body + 1]) return .{ .body = body, .visit = visit, .phase = .settled };
    }

    const visit = if (self.phase == .demanded) self.visit + 1 else trace.demanded.starts[body];

    if (visit < trace.demanded.starts[body + 1]) return .{ .body = body, .visit = visit, .phase = .demanded };

    return .{ .body = body, .visit = trace.planned.starts[body], .phase = .planned };
}

pub const Range = struct {
    end: usize,
    source: enum { empty, recorded, replacement },
};

/// Consecutive accepted bodies backed by the same table; each active body has one visit.
pub fn range(planned: []const u32, changed: []const bool, first: usize) Range {
    if (!@import("genz_options").generated_analysis) {
        const inactive = planned[first] == planned[first + 1];

        return .{ .end = first + 1, .source = if (inactive) .empty else if (changed[first]) .replacement else .recorded };
    }

    const entry = @import("generated_uniqueness_shortcut_range");
    const input: std.meta.Child(entry.Input) = .{ .first = first, .planned = planned, .changed = changed };
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

    return .{ .end = @intCast(result.end), .source = @fromBackingInt(@intCast(@backingInt(result.source))) };
}
