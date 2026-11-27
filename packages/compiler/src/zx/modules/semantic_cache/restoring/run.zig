const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const Artifact = @import("../../artifact/model.zig");
const restore = @import("../restore.zig");
const Current = restore.Current;
const preparation = @import("preparation.zig");
const Publication = @import("publication/host.zig");
const verification = @import("../../artifact/validation/view.zig");
const generated = @import("generated_semantic_restore");
const publish_entry = @import("generated_semantic_restore_publish");
const rollback = @import("generated_semantic_restore_rollback");
const Input = std.meta.Child(generated.Input);
const PublishInput = std.meta.Child(publish_entry.Input);
const type_fields = @typeInfo(zx.ir.TypeStorage).@"struct".field_names;

pub const Frame = struct {
    module: *const Artifact.Module,
    current: *const Current,
    decoded: bool,
    maps: preparation.Maps,
    workspace: std.mem.Allocator,
    scratch: std.mem.Allocator,
    payload: std.mem.Allocator,
    publication: Publication = undefined,
    pub fn execute(self: *Frame, planning: @FieldType(Input, "planning")) Artifact.Error!restore.Restored {
        const current = self.current;
        const type_slots = memory.borrowColumnLengths(current.types);
        const origin_slots = memory.borrowColumnLengths(&current.origins.items);
        const function_slots = memory.borrowColumnLengths(current.functions);
        const types: memory.ColumnLengths = &type_slots;
        const origins: memory.ColumnLengths = &origin_slots;
        const functions: memory.ColumnLengths = &function_slots;
        var counts: [type_fields.len]u64 = undefined;
        var count_view: []u64 = &counts;
        const payload_position = current.payloads.checkpoint();

        self.publication.bind(self);

        const input: Input = .{
            .planning = planning,
            .checkpoint = &.{
                .types = @ptrCast(&types),
                .origins = @ptrCast(&origins),
                .functions = @ptrCast(&functions),
                .type_counts = @ptrCast(&count_view),
            },
            .columns = if (self.publication.has_columns) &self.publication.columns else null,
            .mappings = &self.publication.mappings,
        };

        const restored = (generated.executeIn(self.workspace, &input) catch |err|
            return verification.publicationError(err)) orelse return error.InvalidModule;

        errdefer {
            self.publication.surface.release(self.payload);

            var empty = std.heap.FixedBufferAllocator.init(&.{});

            rollback.executeIn(empty.allocator(), &.{
                .functions = @ptrCast(&functions),
                .function_count = restored.saved.function_count,
                .types = @ptrCast(&types),
                .type_counts = &counts,
                .origins = @ptrCast(&origins),
                .origin_count = restored.saved.origin_count,
            }) catch unreachable;

            current.payloads.rewind(payload_position);
        }

        const publish_input: PublishInput = .{
            .views = &self.publication.input,
            .plan = try zx.columns.bridge(@FieldType(PublishInput, "plan"), self.workspace, &restored.plan),
        };

        const published = publish_entry.executeIn(self.payload, &publish_input) catch |err|
            return verification.publicationError(err);

        const committed = published orelse return error.InvalidModule;
        const verified = try self.publication.validation.execute(self.scratch, committed, &self.publication.empty);

        return self.publication.finish(current, committed, verified);
    }
};

pub fn run(module: *const Artifact.Module, current: *const Current, temporary: std.mem.Allocator, decoded: bool) Artifact.Error!restore.Restored {
    var workspace = zx.Arena.init(temporary);
    var scratch = std.heap.ArenaAllocator.init(temporary);

    defer workspace.deinit();
    defer scratch.deinit();

    var frame: Frame = .{
        .module = module,
        .current = current,
        .decoded = decoded,
        .maps = .{ .allocator = workspace.allocator() },
        .workspace = workspace.allocator(),
        .scratch = scratch.allocator(),
        .payload = current.payloads.allocator(),
    };

    return preparation.execute(&frame);
}

pub fn slot(value: anytype) []std.meta.Child(@TypeOf(value)) {
    return @as(*[1]std.meta.Child(@TypeOf(value)), @ptrCast(value));
}
