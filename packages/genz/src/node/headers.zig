const std = @import("std");
const zx = @import("zx");
const generated = @import("genz_options").generated_analysis;
pub const Error = std.mem.Allocator.Error || error{InvalidAst};

pub fn Counts(comptime Target: type) type {
    const Payloads = @FieldType(std.meta.Child(Target), "payloads");

    return [@typeInfo(Payloads).@"struct".field_names.len]u32;
}

pub fn capacity(existing: usize, count: usize, offsets: usize) Error!void {
    if (count > std.math.maxInt(u32) - existing) {
        if (count != offsets) return error.InvalidAst;

        return error.OutOfMemory;
    }
}

pub fn check(tags: anytype, offsets: []const u32, counts: []u32, limits: ?[]const u64) Error!void {
    if (!generated) {
        if (tags.len != offsets.len) return error.InvalidAst;

        for (tags, offsets) |tag, offset| {
            const index = @backingInt(tag);

            if (limits) |bounds| if (offset >= bounds[index]) return error.InvalidAst;

            counts[index] += 1;
        }

        if (limits == null) for (tags, offsets) |tag, offset| {
            if (offset >= counts[@backingInt(tag)]) return error.InvalidAst;
        };

        return;
    }

    const entry = @import("generated_node_header_check");

    const input: std.meta.Child(entry.Input) = .{
        .tags = bytes(tags),
        .offsets = offsets,
        .mask = mask(std.meta.Elem(@TypeOf(tags))),
        .counts = @ptrCast(&counts),
        .variants = counts.len,
        .limits = limits,
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const valid = zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        error.IndexOutOfBounds => return error.InvalidAst,
        else => unreachable,
    };

    if (!valid) return error.InvalidAst;
}

pub fn rebase(target: anytype, tags: anytype, offsets: []const u32, counts: *const Counts(@TypeOf(target))) void {
    if (tags.len == 0) return;

    if (!generated) {
        for (tags, offsets) |tag, offset| {
            const base = switch (tag) {
                inline else => |selected| @field(target.payloads, @tagName(selected)).count(),
            };

            target.tags.appendAssumeCapacity(tag);
            target.offsets.appendAssumeCapacity(@intCast(base + offset));
        }

        return;
    }

    const bases = payloadBases(target, counts);
    const output_tags = bytes(target.tags.unusedCapacitySlice()[0..tags.len]);
    const output_offsets = target.offsets.unusedCapacitySlice()[0..offsets.len];
    const lengths: zx.memory.ColumnLengths = &.{ &target.tags.items.len, &target.offsets.items.len };
    const entry = @import("generated_node_header_rebase");

    const input: std.meta.Child(entry.Input) = .{
        .tags = bytes(tags),
        .offsets = offsets,
        .mask = mask(std.meta.Elem(@TypeOf(tags))),
        .bases = &bases,
        .target_tags = @ptrCast(&output_tags),
        .target_offsets = @ptrCast(&output_offsets),
        .lengths = @ptrCast(&lengths),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch unreachable;
}

pub fn payloadBases(target: anytype, counts: *const Counts(@TypeOf(target))) Counts(@TypeOf(target)) {
    const names = @typeInfo(@TypeOf(target.payloads)).@"struct".field_names;
    var bases: Counts(@TypeOf(target)) = undefined;

    inline for (names, counts, &bases) |name, count, *base| {
        if (count != 0) base.* = @intCast(@field(target.payloads, name).count());
    }

    return bases;
}

pub fn publishSelected(target: anytype, tags: anytype, written: usize, bases: []u32) void {
    if (written == 0) return;

    if (!generated) {
        for (tags[0..written]) |tag| {
            const index = @backingInt(tag);

            target.tags.appendAssumeCapacity(tag);
            target.offsets.appendAssumeCapacity(bases[index]);

            bases[index] += 1;
        }

        return;
    }

    const output_tags = std.mem.sliceAsBytes(target.tags.unusedCapacitySlice()[0..written]);
    const output_offsets = target.offsets.unusedCapacitySlice()[0..written];
    const lengths: zx.memory.ColumnLengths = &.{ &target.tags.items.len, &target.offsets.items.len };
    const entry = @import("generated_node_header_selected");

    const input: std.meta.Child(entry.Input) = .{
        .tags = bytes(tags),
        .mask = mask(std.meta.Elem(@TypeOf(tags))),
        .count = written,
        .bases = @ptrCast(&bases),
        .target_tags = @ptrCast(&output_tags),
        .target_offsets = @ptrCast(&output_offsets),
        .lengths = @ptrCast(&lengths),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch unreachable;
}

pub fn validateReferences(indices: []const u32, count: usize) Error!void {
    if (!generated) {
        for (indices) |index| if (index >= count) return error.InvalidAst;

        return;
    }

    const entry = @import("generated_node_header_reference_bounds");
    const input: std.meta.Child(entry.Input) = .{ .indices = indices, .count = count };
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    if (!(zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch unreachable)) return error.InvalidAst;
}

pub fn publishReferences(target: anytype, indices: []const u32) void {
    if (!generated) {
        for (indices) |index| {
            target.tags.appendAssumeCapacity(target.tags.items[index]);
            target.offsets.appendAssumeCapacity(target.offsets.items[index]);
        }

        return;
    }

    const output_tags = std.mem.sliceAsBytes(target.tags.unusedCapacitySlice()[0..indices.len]);
    const output_offsets = target.offsets.unusedCapacitySlice()[0..indices.len];
    const lengths: zx.memory.ColumnLengths = &.{ &target.tags.items.len, &target.offsets.items.len };
    const entry = @import("generated_node_header_references");

    const input: std.meta.Child(entry.Input) = .{
        .tags = bytes(target.tags.items),
        .offsets = target.offsets.items,
        .indices = indices,
        .target_tags = @ptrCast(&output_tags),
        .target_offsets = @ptrCast(&output_offsets),
        .lengths = @ptrCast(&lengths),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch unreachable;
}

fn bytes(tags: anytype) []const u8 {
    comptime std.debug.assert(@sizeOf(std.meta.Elem(@TypeOf(tags))) == 1);

    return std.mem.sliceAsBytes(tags);
}

fn mask(comptime Tag: type) u64 {
    // A small enum's byte can contain padding above its backing integer.
    return std.math.maxInt(@Int(.unsigned, @bitSizeOf(Tag)));
}
