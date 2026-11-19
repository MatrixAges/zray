const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const Loaded = @import("../../native.zig");
const Artifact = @import("../../artifact/model.zig");
const restore = @import("../native_restore.zig");
const Mapped = @import("native_input.zig");
const publication = @import("../../link/signature/publication/host.zig");
const type_tail = @import("../../../analysis/semantic/merging/publication/view.zig");
const names = @import("../../../ir/canonical/validation/names/view.zig");
const remap = @import("../../artifact/nodes/remap.zig");
const rule = @import("generated_native_restore_publication");
const Input = std.meta.Child(rule.Input);
const Exports = std.meta.Child(@FieldType(Input, "exports"));
const Members = std.meta.Child(@FieldType(Input, "members"));
const Cached = std.meta.Child(@FieldType(Members, "cached"));
const Stage = publication.Stage(Members);

pub fn apply(allocator: std.mem.Allocator, output: anytype, mapped: *const Mapped, artifact: *const Artifact.Module, current: restore.Current) restore.Error!Loaded.Result {
    const rows = names.borrow(artifact.exports);
    const exports = names.view(std.meta.Child(@FieldType(Exports, "source")), &rows);
    const mapping = remap.typeMapping(std.meta.Child(@FieldType(Exports, "types")), .{ .mapped = @ptrCast(mapped.type_ids) });
    var target: []memory.NamedId = &.{};
    var written: [1]u64 = .{0};
    const progress: []u64 = &written;

    errdefer {
        for (target[0..@intCast(written[0])]) |item| allocator.free(item.name);

        allocator.free(target);
    }

    var stage: Stage = undefined;

    stage.init(&allocator, current.functions);

    const types = zx.columns.view(ir.TypeTable, output.types);

    const options: type_tail.Options = .{
        .allocator = allocator,
        .payload = allocator,
        .types = current.types,
        .origins = &current.origins.items,
        .offsets = &type_tail.offsets(current.types),
    };

    var tail: type_tail = undefined;

    tail.init(&options, types, output.origins);
    errdefer tail.release(&options);

    const cached: Cached = .{
        .signatures = &zx.columns.columns(std.meta.Child(@FieldType(Cached, "signatures")), artifact.functions),
        .inputs = mapped.input_ids,
        .outputs = mapped.output_ids,
    };

    const input: Input = .{
        .exports = &.{
            .source = &exports,
            .types = &mapping,
            .target = @ptrCast(&target),
            .progress = @ptrCast(&progress),
        },
        .members = &.{
            .cached = &cached,
            .module = @backingInt(current.module),
            .destination = &stage.destination,
            .members = &stage.output.view,
            .member_storage = @ptrCast(&stage.output.buffer),
            .first = current.functions.count(),
            .empty = &Stage.empty(std.meta.Child(@FieldType(Members, "empty"))),
        },
        .types = &ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), types),
        .origins = zx.columns.pointer(@FieldType(Input, "origins"), output.origins),
        .destination = &tail.target,
    };

    const namespace = rule.executeIn(allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return .{
        .types = current.types.view(),
        .exports = @ptrCast(target),
        .members = stage.members(),
        .namespace = namespace,
    };
}
