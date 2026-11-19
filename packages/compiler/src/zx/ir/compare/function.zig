const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;

pub const borrow = @import("borrow.zig");
pub const initializer = @import("initializer.zig");
pub const bodies = @import("referenced/host.zig").bodies;

pub fn headers(left: *const ir.FunctionTable, right: *const ir.FunctionTable, start: usize, end: usize) bool {
    if (start == end) return true;

    const entry = @import("generated_ir_compare_header");
    const Input = std.meta.Child(entry.Input);
    const Pair = std.meta.Child(@FieldType(Input, "columns"));
    const View = std.meta.Child(@FieldType(Pair, "left"));
    const Native = std.meta.Child(@FieldType(Input, "native"));
    const NativeColumns = std.meta.Child(@FieldType(Native, "left"));
    var lhs: borrow.Header = undefined;
    var rhs: borrow.Header = undefined;

    lhs.borrowRange(.{left}, start, end);
    rhs.borrowRange(.{right}, start, end);

    const a = lhs.view(View);
    const b = rhs.view(View);
    const native_left = native(NativeColumns, left, start, end);
    const native_right = native(NativeColumns, right, start, end);

    const input: Input = .{
        .columns = &.{ .left = &a, .right = &b, .masks = &borrow.Header.masks },
        .native = &.{ .left = &native_left, .right = &native_right },
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeIn(fixed.allocator(), &input) catch unreachable;
}

fn native(comptime View: type, table: *const ir.FunctionTable, start: usize, end: usize) View {
    var result: View = undefined;

    inline for (@typeInfo(View).@"struct".field_names) |name| {
        @field(result, name) = @field(table, name)[start..end];
    }

    return result;
}
