const std = @import("std");
const zx = @import("zx");
const Origins = @import("../nominal_origins.zig");
const Native = @import("../interface.zig").Native;
const Target = @import("../native.zig").Target;
const generated = @import("generated_native_interface");
const delivery = @import("generated_native_interface_delivery");
const publication = @import("../../analysis/semantic/merging/commit.zig");
const signatures = @import("../link/signature/publication/host.zig");
const destination = @import("../link/signature/publication/destination.zig");
const Delivery = std.meta.Child(delivery.Input);
const Members = std.meta.Child(@FieldType(Delivery, "members"));
const Exports = std.meta.Child(@FieldType(Delivery, "exports"));
const Rows = std.meta.Child(@FieldType(Members, "rows"));

pub const Result = struct {
    exports: []const zx.ir.Export,
    members: @import("../native.zig").PublishedMembers,
    namespace: ?[]const []const u8 = null,
};

pub fn analyze(allocator: std.mem.Allocator, entry: Native, module: zx.ir.NativeModuleId, target: Target, reporter: *zx.Reporter) zx.Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const Input = std.meta.Child(generated.Input);
    const Table = std.meta.Child(@FieldType(Input, "base"));
    const base = zx.ir.TypeTable.borrow(Table, target.types.view());
    const Bindings = std.meta.Child(@FieldType(Input, "origins"));
    const Origin = std.meta.Child(@FieldType(Input, "origin"));
    const origins = Origins.Table.borrow(Bindings, target.origins.?.items.view());
    const owner = target.owner.?;
    const origin: Origin = .{ .kind = @intFromEnum(@as(std.meta.Tag(Origins.Origin), .native)), .owner = owner, .member = "" };

    const input: Input = .{
        .shared = true,
        .origins = &origins,
        .origin = &origin,
        .namespace = entry.namespace,
        .base = &base,
        .source = entry.source,
    };

    const result = generated.execute(&arena, &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return reporter.fail(.contract, .{ .start = 0, .end = 0 }, try std.fmt.allocPrint(allocator, "internal compiler error: generated native analysis failed with {s}", .{@errorName(err)})),
    };

    if (result.diagnostic.message.len != 0) return reporter.fail(
        std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), result.diagnostic.code) orelse unreachable,
        .{ .start = @intCast(result.diagnostic.start), .end = @intCast(result.diagnostic.end) },
        try allocator.dupe(u8, result.diagnostic.message),
    );

    var types = publication.Interface.init(allocator, target.types, &target.origins.?.items, result.delta, result.origins);

    types.native_owner = owner;
    const functions = target.functions.?;
    const exports = try allocator.alloc(zx.ir.Export, result.exports.len);
    const rows = zx.memory.borrowNamedRows("type_id", exports);
    var stage: signatures.Stage(Members) = undefined;

    stage.init(&allocator, functions);

    const request: Delivery = .{
        .types = @ptrCast(&types),
        .exports = &Exports{ .source = zx.columns.slice(@FieldType(Exports, "source"), result.exports), .target = @ptrCast(&rows) },
        .members = &Members{
            .rows = &Rows{ .fresh = zx.columns.slice(@FieldType(Rows, "fresh"), result.members), .cached = null, .count = result.members.len },
            .owner = &.{ .path = entry.path, .namespace = entry.namespace, .module = @backingInt(module) },
            .destination = &stage.functions.input,
            .members = &stage.output.view,
            .member_storage = @ptrCast(&stage.output.buffer),
            .first = functions.count(),
            .empty = &destination.empty(std.meta.Child(@FieldType(Members, "empty"))),
        },
    };

    const namespace = delivery.executeIn(allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return reporter.fail(.contract, .{ .start = 0, .end = 0 }, try std.fmt.allocPrint(allocator, "internal compiler error: generated native delivery failed with {s}", .{@errorName(err)})),
    };

    return .{ .exports = exports, .members = stage.members(), .namespace = namespace };
}
