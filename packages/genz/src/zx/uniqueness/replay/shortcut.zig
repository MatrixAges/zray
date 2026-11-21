const std = @import("std");
const Trace = @import("../trace.zig");
const Cursor = @This();

body: usize = 0,
visit: usize = 0,

phase: enum { start, settled, demanded, planned, done, reject } = .start,
pub fn nextSeed(self: Cursor, active: []const bool, trace: *const Trace, changed: []const bool, agreed: bool) Cursor {
    if (!agreed) return .{ .body = self.body, .visit = self.visit, .phase = .reject };

    var body = self.body;

    if (self.phase == .start or self.phase == .planned) {
        if (self.phase == .planned) body += 1;

        while (body < active.len) : (body += 1) {
            if (!active[body]) continue;
            if (trace.planned.starts[body + 1] - trace.planned.starts[body] != 1) return .{ .body = body, .phase = .reject };
            if (changed[body]) break;
        }

        if (body == active.len) return .{ .body = body, .phase = .done };
    }

    if (self.phase != .demanded) {
        const visit = if (self.phase == .settled) self.visit + 1 else trace.settled.starts[body];

        if (visit < trace.settled.starts[body + 1]) return .{ .body = body, .visit = visit, .phase = .settled };
    }

    const visit = if (self.phase == .demanded) self.visit + 1 else trace.demanded.starts[body];

    if (visit < trace.demanded.starts[body + 1]) return .{ .body = body, .visit = visit, .phase = .demanded };

    return .{ .body = body, .visit = trace.planned.starts[body], .phase = .planned };
}

pub const Replacement = struct { visit: u32, value: @import("../memo.zig").Planned };

pub fn publish(allocator: std.mem.Allocator, trace: *Trace, replay: *const Trace.Replay, replacements: []const Replacement, active: []const bool) std.mem.Allocator.Error!@import("../root.zig").Result {
    const PlanWriter = @import("../program/visit/plan_writer.zig");
    var output = try PlanWriter.init(allocator, active);

    if (@import("genz_options").generated_analysis) {
        try @import("shortcut/publication.zig").apply(allocator, trace, replay, replacements, &output);
    } else {
        var position: usize = 0;

        for (replay.changed, 0..) |changed, index| {
            const first = trace.planned.starts[index];

            if (first == trace.planned.starts[index + 1]) continue;

            const record = if (changed) replacements[position].value else trace.planned.entries[first].value;

            output.putSeed(index, try record.plan().copy(allocator));

            position += @intFromBool(changed);
        }

        for (replacements) |change| trace.planned.entries[change.visit].value = change.value;

        @memcpy(trace.identities, replay.identities);
    }

    return output.result();
}
