const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const Artifact = @import("../../artifact/model.zig");
const Current = @import("../native_restore.zig").Current;
const OriginTable = @import("../../nominal_origins.zig").Table;
const publication = @import("../../link/signature/publication/host.zig");
const function_target = @import("../../link/signature/publication/destination.zig");
const native_bindings = @import("../../link/signature/publication/native_bindings.zig");
const TypeTail = @import("../../../analysis/semantic/merging/publication/view.zig");
const Restore = std.meta.Child(@import("generated_native_restore").Input);
const Target = std.meta.Child(@FieldType(Restore, "target"));
const Bindings = std.meta.Child(@FieldType(Target, "bindings"));
const Native = std.meta.Child(@FieldType(Target, "native"));
const Members = std.meta.Child(@FieldType(Target, "members"));
const Exports = std.meta.Child(@FieldType(Target, "exports"));
const empty = function_target.empty(std.meta.Child(@FieldType(Members, "empty")));
const Self = @This();

exports: []const memory.NamedId,
written: [1]u64,
progress: []u64,
export_view: Exports,
functions: publication.Stage(Members),
member_view: Members,
bindings: native_bindings.View(Bindings, Native),
offsets: TypeTail.Offsets,
options: TypeTail.Options,
tail: TypeTail,
input: Target,
pub fn init(self: *Self, allocator: std.mem.Allocator, scope: *memory.ArenaScope, artifact: *const Artifact.Module, current: Current) void {
    self.exports = &.{};
    self.written = .{0};
    self.progress = &self.written;
    self.export_view = .{ .target = @ptrCast(&self.exports), .progress = @ptrCast(&self.progress) };
    self.offsets = TypeTail.offsets(current.types);

    self.options = .{
        .allocator = allocator,
        .payload = allocator,
        .types = current.types,
        .origins = &current.origins.items,
        .offsets = &self.offsets,
    };

    self.tail.init(&self.options, .{}, OriginTable{});
    self.bindings.init(current.modules, current.functions, current.module, &self.exports, artifact.exports.len);
    self.functions.init(&self.options.allocator, current.functions);

    self.member_view = .{
        .destination = &self.functions.functions.input,
        .members = &self.functions.output.view,
        .member_storage = @ptrCast(&self.functions.output.buffer),
        .first = current.functions.count(),
        .empty = &empty,
    };

    const tail: *const TypeTail.Target = &self.tail.target;

    self.input = .{
        .scope = @ptrCast(scope),
        .resource = @ptrCast(&self.options.allocator),
        .exports = &self.export_view,
        .members = &self.member_view,
        .bindings = &self.bindings.exports,
        .native = &self.bindings.destination,
        .destination = zx.columns.pointer(@FieldType(Target, "destination"), tail),
    };
}

pub fn release(self: *const Self, allocator: std.mem.Allocator) void {
    self.tail.release();
    self.bindings.release(allocator);

    for (self.exports[0..@intCast(self.written[0])]) |item| allocator.free(item.name);

    allocator.free(self.exports);
}
