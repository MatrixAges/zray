const std = @import("std");
const zx = @import("zx");
const Module = @import("../artifact/model.zig").Module;
const Target = @import("../module_record.zig").Target;
pub const Error = @import("graph/seed.zig").Error;

pub const Plan = struct {
    registration: []const u64,
    entry: usize,
    dependencies: []const u64,
    paths: []const []const u8 = &.{},
    buckets: []const ?u32 = &.{},
    offsets: []const u64 = &.{},
    targets: []const u64 = &.{},
    pub fn sources(self: Plan, row: usize) []const u64 {
        return self.targets[@intCast(self.offsets[row])..@intCast(self.offsets[row + 1])];
    }
};

pub fn prepare(allocator: std.mem.Allocator, modules: []const Module, entry: []const u8) Error!Plan {
    if (comptime !@import("parser_options").generated_parser) {
        const order = try @import("graph/seed.zig").order(allocator, modules, entry);

        return .{ .registration = order, .entry = @intCast(order[order.len - 1]), .dependencies = order[0 .. order.len - 1] };
    }

    const paths = try allocator.alloc([]const u8, modules.len);
    const offsets = try allocator.alloc(u64, modules.len + 1);
    const order = try allocator.alloc(u64, modules.len);
    const source_paths = zx.memory.borrowTextColumn("path", modules);
    const generated = @import("generated_artifact_graph");
    const Input = std.meta.Child(generated.Input);
    const kinds = zx.memory.borrowNestedListColumn(Target.Kind, "dependencies", &.{ "target", "kind" }, modules);
    const dependency_paths = zx.memory.borrowNestedListColumn([]const u8, "dependencies", &.{ "target", "path" }, modules);

    const input: Input = .{
        .paths = paths,
        .path_columns = &.{ .source = @ptrCast(&source_paths), .target = @ptrCast(&paths), .count = paths.len },
        .dependencies = &.{
            .kinds = @ptrCast(&kinds),
            .paths = @ptrCast(&dependency_paths),
            .kind_stride = kinds.stride,
            .source_kind = @backingInt(Target.Kind.source),
        },
        .offsets = offsets,
        .offset_target = @ptrCast(&offsets),
        .entry = entry,
        .order = @ptrCast(&order),
        .order_rows = order,
        .capacity = order.len,
    };

    const plan = zx.columns.invoke(generated.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    switch (plan.status) {
        .Invalid => return error.InvalidModule,
        .Missing => return error.MissingModule,
        .Cycle => return error.CyclicDependency,
        .Ready => {},
    }

    return .{
        .registration = plan.registration,
        .entry = @intCast(plan.entry orelse return error.InvalidModule),
        .dependencies = plan.dependencies,
        .paths = paths,
        .buckets = plan.buckets,
        .offsets = offsets,
        .targets = plan.targets,
    };
}
