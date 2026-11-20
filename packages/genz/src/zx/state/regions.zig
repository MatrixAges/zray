const std = @import("std");
const node = @import("../../node.zig");
const Builder = @import("../../builder.zig");
const Object = @import("../state.zig").Object;
const storage = @import("storage.zig");

pub fn lower(builder: Builder, declarations: *std.ArrayList(node.Declaration), objects: []const Object) std.mem.Allocator.Error!void {
    try @import("region.zig").lower(builder, declarations, storage.writable(objects));
    try declarations.append(builder.allocator, try @import("reclaim.zig").lower(builder, objects, storage.reclaimable(objects)));
}
