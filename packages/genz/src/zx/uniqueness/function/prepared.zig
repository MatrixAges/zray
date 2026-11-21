const std = @import("std");
const zx = @import("zx");
const View = @import("../program/bodies.zig").View;
const Slots = @import("../slots.zig");
const Summaries = @import("../summaries.zig");
const generated = @import("generated_uniqueness_function_prepare");
const Input = std.meta.Child(generated.Input);
pub const Facts = std.meta.Child(generated.Output);

pub fn build(owner: std.mem.Allocator, workspace: std.mem.Allocator, body: View, slots: Slots, summaries: *const Summaries) std.mem.Allocator.Error!*const Facts {
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    var time: []u32 = &.{};
    var finish: []u32 = &.{};
    var region: []u32 = &.{};
    var repeated: []u32 = &.{};
    var scope = zx.memory.ArenaScope{ .active = scratch.allocator() };

    errdefer owner.free(time);
    errdefer owner.free(finish);
    errdefer owner.free(region);
    errdefer owner.free(repeated);

    const Source = std.meta.Child(@FieldType(Input, "source"));
    const block = body.control.block();

    const source: Source = .{
        .expressions = zx.columns.pointer(@FieldType(Source, "expressions"), body.expressions),
        .control = zx.columns.pointer(@FieldType(Source, "control"), block.control),
        .symbols = body.symbols.count(),
        .first = @intCast(block.first),
        .count = @intCast(block.len),
    };

    const input: Input = .{
        .source = &source,
        .symbols = body.symbols.types,
        .counts = slots.counts,
        .layout = &.{ .offsets = slots.offsets, .members = @ptrCast(slots.members), .unwrapped = @ptrCast(slots.unwrapped) },
        .held = summaries.held,
        .written = summaries.written,
        .effects = summaries.effects,
        .nodes = &.{
            .time = @ptrCast(&time),
            .finish = @ptrCast(&finish),
            .region = @ptrCast(&region),
            .repeated = @ptrCast(&repeated),
        },
        .scope = @ptrCast(&scope),
        .owner = @ptrCast(&owner),
    };

    return generated.executeIn(scope.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}
