const std = @import("std");
const zx = @import("zx");
const Function = @import("../function.zig");
const Slots = @import("../slots.zig");
const Summaries = @import("../summaries.zig");
const generated = @import("generated_uniqueness_function_prepare");
const Input = std.meta.Child(generated.Input);
pub const Facts = std.meta.Child(generated.Output);

pub fn build(owner: std.mem.Allocator, workspace: std.mem.Allocator, unit: *const Function.Unit, block: zx.ir.Block, slots: Slots, summaries: *const Summaries) std.mem.Allocator.Error!Facts {
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const Source = std.meta.Child(@FieldType(Input, "source"));

    const source: Source = .{
        .expressions = zx.columns.pointer(@FieldType(Source, "expressions"), &unit.expressions),
        .control = zx.columns.pointer(@FieldType(Source, "control"), block.control),
        .symbols = unit.symbols.count(),
        .first = @intCast(block.first),
        .count = @intCast(block.len),
    };

    const input: Input = .{
        .source = &source,
        .symbols = unit.symbols.types,
        .counts = slots.counts,
        .layout = &.{ .offsets = slots.offsets, .members = @ptrCast(slots.members), .unwrapped = @ptrCast(slots.unwrapped) },
        .held = summaries.held,
        .written = summaries.written,
        .effects = summaries.effects,
    };

    const output = generated.executeIn(scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return retain(owner, output.*);
}

/// Only the published column descriptors and their scalar slices survive the preparation arena.
fn retain(owner: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .@"struct" => |record| {
            var result: T = undefined;

            inline for (record.field_names) |name| @field(result, name) = try retain(owner, @field(value, name));

            return result;
        },
        .pointer => |pointer| switch (pointer.size) {
            .one => {
                const result = try owner.create(pointer.child);

                result.* = try retain(owner, value.*);

                return result;
            },
            .slice => return switch (@typeInfo(pointer.child)) {
                .int, .bool, .@"enum" => try owner.dupe(pointer.child, value),
                else => @compileError("expected a scalar fact column"),
            },
            else => @compileError("expected a fact descriptor or column"),
        },
        .int, .bool, .@"enum" => return value,
        else => @compileError("unexpected function fact"),
    }
}
