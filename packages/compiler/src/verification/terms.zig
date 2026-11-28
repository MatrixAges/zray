const std = @import("std");
const ir = @import("zx").ir;
const numeric = @import("generated_verification_numeric");

pub const Value = struct {
    scalar: ?[]const u8 = null,
    fields: []const Value = &.{},
    pub fn borrow(scalar: ?[]const u8, fields: []const u8) Value {
        if (fields.len == 0) return .{ .scalar = scalar };

        const bytes: []align(@alignOf(Value)) const u8 = @alignCast(fields);

        return .{ .scalar = scalar, .fields = std.mem.bytesAsSlice(Value, bytes) };
    }

    pub fn layout(comptime Layout: type) Layout {
        return .{
            .width = @sizeOf(Value),
            .text = @offsetOf(Value, "scalar"),
            .children = @offsetOf(Value, "fields"),
        };
    }
};

pub const Evaluation = struct {
    value: Value,
    safe: []const u8 = "true",
    pub fn fromView(source: anytype) Evaluation {
        return .{ .value = Value.borrow(source.text, source.fields), .safe = source.safe };
    }
    pub fn view(self: Evaluation, comptime View: type, allocator: std.mem.Allocator) std.mem.Allocator.Error!View {
        const result = try allocator.create(std.meta.Child(View));
        result.* = self.descriptor(std.meta.Child(View));

        return result;
    }

    pub fn descriptor(self: Evaluation, comptime View: type) View {
        return .{ .safe = self.safe, .text = self.value.scalar, .fields = std.mem.sliceAsBytes(self.value.fields) };
    }
};

/// A width of zero denotes an SMT Bool. Enumeration members share their bit-vector sort.
pub fn symbolicWidth(target: ir.Type) ?u16 {
    const input: std.meta.Child(numeric.Input) = switch (target) {
        .scalar => |scalar| .{ .scalar = @backingInt(scalar), .members = null },
        .enumeration => |enumeration| .{ .scalar = null, .members = enumeration.members.len },
        else => return null,
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return numeric.executeIn(scratch.allocator(), &input) catch unreachable;
}
