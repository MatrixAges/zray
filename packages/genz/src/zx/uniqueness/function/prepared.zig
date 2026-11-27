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
    };

    const built = generated.executeIn(scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return retainFacts(owner, built);
}

fn retainFacts(owner: std.mem.Allocator, built: *const Facts) std.mem.Allocator.Error!*const Facts {
    const owned = try owner.create(Facts);

    owned.* = try retainStruct(Facts, owner, built.*);

    return owned;
}

fn retainStruct(comptime T: type, owner: std.mem.Allocator, value: T) std.mem.Allocator.Error!T {
    var result: T = undefined;

    inline for (@typeInfo(T).@"struct".field_names) |name| {
        @field(result, name) = try retainValue(@FieldType(T, name), owner, @field(value, name));
    }

    return result;
}

fn retainValue(comptime T: type, owner: std.mem.Allocator, value: T) std.mem.Allocator.Error!T {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                if (value.len == 0) return &.{};

                if (comptime containsPointers(ptr.child)) {
                    const items = try owner.alloc(ptr.child, value.len);

                    for (items, value) |*dst, item| dst.* = try retainValue(ptr.child, owner, item);

                    return items;
                }

                return try owner.dupe(ptr.child, value);
            },
            .one => {
                const copy = try owner.create(ptr.child);
                copy.* = try retainValue(ptr.child, owner, value.*);

                return copy;
            },
            else => @compileError("unsupported pointer size"),
        },
        .optional => |opt| if (value) |inner| try retainValue(opt.child, owner, inner) else null,
        .@"struct" => try retainStruct(T, owner, value),
        else => value,
    };
}

fn containsPointers(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |opt| containsPointers(opt.child),
        .@"struct" => |st| blk: {
            for (st.field_names) |name| {
                if (containsPointers(@FieldType(T, name))) break :blk true;
            }

            break :blk false;
        },
        else => false,
    };
}
