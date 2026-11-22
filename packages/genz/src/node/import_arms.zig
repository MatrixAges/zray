const std = @import("std");
const node = @import("../node.zig");
const transfer = @import("zx").memory.column_transfer;
const payloads = @import("import_payloads.zig");
const generated = @import("genz_options").generated_analysis;
pub const Error = std.mem.Allocator.Error || error{InvalidAst};

pub fn append(allocator: std.mem.Allocator, target: anytype, source: anytype) Error!void {
    const count = source.value.len;

    if (generated) {
        const columns = [_]transfer.Column{
            transfer.bind(&target.fields.value.values, source.value, false, true),
            transfer.bind(&target.fields.capture.values, source.capture, true, false),
            transfer.bind(&target.fields.result.values, source.result, false, true),
        };

        return payloads.Plain.append(allocator, &columns, count, target.count(), false);
    }

    inline for (@typeInfo(std.meta.Child(@TypeOf(source))).@"struct".field_names) |name| {
        if (@field(source, name).len != count) return error.InvalidAst;
    }

    if (count > std.math.maxInt(u32) - target.count()) return error.OutOfMemory;
    try target.reserve(allocator, count);

    for (0..count) |index| target.append(node.SelectionArm{
        .value = if (source.value[index]) |id| @fromBackingInt(id) else null,
        .capture = if (source.capture[index]) |text| try allocator.dupe(u8, text) else null,
        .result = @fromBackingInt(source.result[index]),
    });
}
