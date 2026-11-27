const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Current = @import("../native_restore.zig").Current;
const Loaded = @import("../../native.zig");
const publication = @import("../../native/publication/host.zig");
const function_target = @import("../../link/signature/publication/destination.zig");
const TypeTail = @import("../../../analysis/semantic/merging/publication/view.zig");
const Publish = std.meta.Child(@import("generated_native_restore_publish").Input);
const Members = std.meta.Child(@FieldType(Publish, "members"));
const empty = function_target.empty(std.meta.Child(@FieldType(Members, "empty")));
const Self = @This();

members: Members,
offsets: TypeTail.Offsets,
tail: TypeTail,
pub fn init(self: *Self, allocator: std.mem.Allocator, current: Current) void {
    self.offsets = TypeTail.offsets(current.types);

    self.tail.init(.{
        .allocator = allocator,
        .payload = allocator,
        .types = current.types,
        .origins = &current.origins.items,
        .offsets = &self.offsets,
    });

    self.members = .{ .first = current.functions.count(), .empty = &empty };
}

pub fn commit(self: *Self, allocator: std.mem.Allocator, current: Current, value: anytype) std.mem.Allocator.Error!Loaded.Result {
    const exports = try allocator.alloc(ir.Export, value.exports.rows.len);

    errdefer allocator.free(exports);

    for (value.exports.rows, exports) |row, *slot| {
        slot.* = .{ .name = row.name, .type_id = @fromBackingInt(row.type_id) };
    }

    const members = try publication.ownBindings(allocator, value.members);

    errdefer allocator.free(members);

    try current.functions.reserve(allocator, value.functions.len);
    try self.tail.commit(value.publication);

    const module = @backingInt(current.module);

    publication.appendColumnsAssumeCapacity(current.functions, value.functions);

    current.modules.type_namespaces.items[module] = value.namespace;
    current.modules.type_names.items[module] = value.exports.names;
    current.modules.type_ids.items[module] = value.exports.ids;

    return .{ .types = current.types.view(), .exports = exports, .members = members };
}
