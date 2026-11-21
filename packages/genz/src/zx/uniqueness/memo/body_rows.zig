const std = @import("std");
const zx = @import("zx");
const Bodies = @import("../program/bodies.zig");
const Growth = @import("../growth.zig");
const Level = @import("../level.zig").Level;
const Digest = @import("../memo.zig").Digest;
const Summaries = @import("../summaries.zig");
const Self = @This();
const no_identity: Digest = @splat(0);

identities: zx.memory.ReadColumn,
callees: []const []const u32,
sources: [4]zx.memory.ListColumn,
projected: [4]zx.memory.ReadColumn,
projection: zx.memory.ListProjection,
pub fn init(self: *Self, bodies: *const Bodies) void {
    const units = bodies.units;
    self.identities = zx.memory.borrowNestedColumn(Digest, &.{}, bodies.identities);
    self.callees = bodies.callees;

    self.sources = .{
        zx.memory.borrowListPath(@FieldType(Growth.Normalized, "id"), &.{ "growth", "normalized" }, &.{"id"}, units),
        zx.memory.borrowListPath(Level, &.{ "growth", "normalized" }, &.{"want"}, units),
        zx.memory.borrowListPath(u64, &.{ "growth", "renewed" }, &.{"key"}, units),
        zx.memory.borrowListPath(Level, &.{ "growth", "renewed" }, &.{"want"}, units),
    };

    self.projection = .{ .sources = &self.sources, .target = &self.projected };
}

pub fn Views(comptime View: type) type {
    const Projection = std.meta.Child(@FieldType(View, "growth"));
    const Records = std.meta.Child(@FieldType(Projection, "normalized"));

    return struct { growth: Projection, normalized: Records, renewed: Records };
}

pub fn view(self: *const Self, comptime View: type, views: *Views(View)) View {
    views.* = .{
        .growth = .{
            .projection = @ptrCast(&self.projection),
            .normalized = &views.normalized,
            .renewed = &views.renewed,
        },
        .normalized = .{ .keys = @ptrCast(&self.projected[0]), .wants = @ptrCast(&self.projected[1]) },
        .renewed = .{ .keys = @ptrCast(&self.projected[2]), .wants = @ptrCast(&self.projected[3]) },
    };

    return .{ .identities = @ptrCast(&self.identities), .callees = self.callees, .growth = &views.growth, .empty_identity = &no_identity };
}

pub fn summaries(comptime View: type, source: *const Summaries) View {
    return zx.columns.borrow(View, &.{
        .inputs = @as([]const []const u8, @ptrCast(source.input)),
        .called_outputs = @as([]const []const u8, @ptrCast(source.output)),
        .output_wants = @as([]const []const u8, @ptrCast(source.outputs)),
        .called_input_wants = @as([]const []const u8, @ptrCast(source.inputs)),
    });
}
