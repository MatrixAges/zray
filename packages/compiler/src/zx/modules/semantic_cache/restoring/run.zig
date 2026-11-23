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
const rollback = @import("generated_semantic_restore_rollback");
const Input = std.meta.Child(generated.Input);
const type_fields = @typeInfo(zx.ir.TypeStorage).@"struct".field_names;

pub const Frame = struct {
    module: *const Artifact.Module,
    current: *const Current,
    decoded: bool,
    maps: preparation.Maps,
    scratch: std.mem.Allocator,
    payload: std.mem.Allocator,
    scope: memory.ArenaScope,
    publication: Publication = undefined,
    saved: bool = false,
    function_count: u64 = undefined,
    origin_count: u64 = undefined,
    pub fn execute(self: *Frame, planning: @FieldType(Input, "planning")) Artifact.Error!restore.Restored {
        const current = self.current;
        const type_slots = memory.borrowColumnLengths(current.types);
        const origin_slots = memory.borrowColumnLengths(&current.origins.items);
        const function_slots = memory.borrowColumnLengths(current.functions);
        const types: memory.ColumnLengths = &type_slots;
        const origins: memory.ColumnLengths = &origin_slots;
        const functions: memory.ColumnLengths = &function_slots;
        var counts: [type_fields.len]u64 = undefined;
        const count_view: []u64 = &counts;
        const saved_functions = slot(&self.function_count);
        const saved_origins = slot(&self.origin_count);
        const saved_columns = slot(&self.saved);
        const payload_position = current.payloads.checkpoint();

        self.publication.bind(self);

        errdefer if (self.saved) {
            self.publication.surface.release(self.payload);

            var empty = std.heap.FixedBufferAllocator.init(&.{});

            rollback.executeIn(empty.allocator(), &.{
                .functions = @ptrCast(&functions),
                .function_count = self.function_count,
                .types = @ptrCast(&types),
                .type_counts = &counts,
                .origins = @ptrCast(&origins),
                .origin_count = self.origin_count,
            }) catch unreachable;

            current.payloads.rewind(payload_position);
        };

        const input: Input = .{
            .planning = planning,
            .checkpoint = &.{
                .types = @ptrCast(&types),
                .origins = @ptrCast(&origins),
                .functions = @ptrCast(&functions),
                .type_counts = @ptrCast(&count_view),
                .function_count = @ptrCast(&saved_functions),
                .origin_count = @ptrCast(&saved_origins),
                .saved = @ptrCast(&saved_columns),
            },
            .publication = &self.publication.input,
        };

        const result = generated.executeIn(self.scope.allocator(), &input) catch |err|
            return verification.failure(&self.scope, self.scratch, err);

        return self.publication.finish(current, result orelse return error.InvalidModule);
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
        .scratch = scratch.allocator(),
        .payload = current.payloads.allocator(),
        .scope = .{ .active = workspace.allocator() },
    };

    return preparation.execute(&frame);
}

pub fn slot(value: anytype) []std.meta.Child(@TypeOf(value)) {
    return @as(*[1]std.meta.Child(@TypeOf(value)), @ptrCast(value));
}
