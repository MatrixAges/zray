const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const Case = @import("../project/flow.zig").Case;
const condition = @import("../condition.zig");
const Result = frontend.ExpressionInput.Result;
const boolean_domain_size = 2;
const Coverage = struct { stopped: bool, remaining: ?bool };
const Self = @This();

allocator: std.mem.Allocator,
owner: []const u8,
pending: std.ArrayList(Result) = .empty,
taken: usize = 0,
coverage: Coverage = .{ .stopped = false, .remaining = null },
pub fn deinit(self: *Self) void {
    for (self.pending.items[self.taken..]) |*parsed| parsed.deinit();

    self.pending.deinit(self.allocator);
}

pub fn label(self: *Self, attribute: rx.ast.Attribute) std.mem.Allocator.Error!Result {
    if (self.taken == self.pending.items.len) return @import("../attribute.zig").parseBorrowed(self.allocator, attribute, self.owner);

    const parsed = self.pending.items[self.taken];

    self.taken += 1;

    return parsed;
}

pub fn observe(self: *Self, truth: ?bool) void {
    if (self.coverage.stopped) return;

    const next = if (truth) |value| !value else null;
    const stopped = next == null or (self.coverage.remaining != null and self.coverage.remaining != next);

    self.coverage = .{ .stopped = stopped, .remaining = if (stopped) null else next };
}

/// Look ahead only while every explicit label may exclude the same boolean value.
/// Retain a boolean domain's worth of labels for normal analysis in source order.
/// A run of repeated labels can still be scanned without retaining its syntax.
pub fn remaining(self: *Self, rest: []const Case) std.mem.Allocator.Error!?bool {
    for (rest) |case| {
        if (self.coverage.stopped) break;

        const attribute = case.label.attribute() orelse continue;

        self.observe(try self.lookAhead(attribute));
    }

    self.coverage.stopped = true;

    return self.coverage.remaining;
}

pub fn lookAhead(self: *Self, attribute: rx.ast.Attribute) std.mem.Allocator.Error!?bool {
    const retain = self.pending.items.len < boolean_domain_size;

    if (retain) try self.pending.ensureTotalCapacityPrecise(self.allocator, boolean_domain_size);

    var parsed = try @import("../attribute.zig").parseBorrowed(self.allocator, attribute, self.owner);
    const truth = condition.boolean(&parsed);

    if (retain) {
        self.pending.appendAssumeCapacity(parsed);
    } else {
        parsed.deinit();
    }

    return truth;
}
