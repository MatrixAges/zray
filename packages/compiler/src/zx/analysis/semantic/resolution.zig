const std = @import("std");
const zx = @import("zx");
const Types = @import("../types.zig");
const generated = @import("generated_type_resolution");
const model = @import("resolving/host/model.zig");
const Source = @import("resolving/host/source.zig");
const Origins = @import("../../modules/nominal_origins.zig");
const TypeTail = @import("merging/publication/view.zig");
const Names = @import("resolving/host/names.zig");

pub fn Request(comptime View: type) type {
    return struct {
        initialize: bool = false,
        name: ?zx.ast.Name = null,
        node: ?View.Ref = null,
    };
}

pub fn execute(types: *Types, view: anytype, request: Request(@TypeOf(view))) zx.Error!zx.ir.TypeId {
    var arena = std.heap.ArenaAllocator.init(types.scratch orelse types.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    var source: Source = .{};

    try source.init(allocator, view, request.node);

    const base = zx.ir.TypeTable.borrow(model.Table, types.items.view());
    const Aliases = std.meta.Child(@FieldType(model.Context, "aliases"));
    const aliases = @import("resolving/host/aliases.zig").borrow(types.aliases);
    const alias_view = aliases.view(Aliases);
    const resolved = types.resolved.view(model.Cache);

    const context: model.Context = .{
        .source = &source.value,
        .base = &base,
        .resolved = &resolved,
        .aliases = &alias_view,
        .visiting = types.visiting.keys(),
        .native_interface = types.native_interface,
    };

    const name = if (request.name) |value| @import("resolving/host/native.zig").named(value) else model.empty_name;
    const delta = zx.ir.TypeTable.borrow(model.Table, .{});
    const cache: model.Cache = .{ .names = &.{}, .ids = &.{} };
    const selected: model.Request = .{ .context = &context, .delta = &delta, .cache = &cache, .initialize = request.initialize, .named = request.name != null, .name = &name, .reference = &source.reference };
    const origins = Origins.Table.borrow(model.Bindings, if (types.shared) |shared| shared.origins.items.view() else .{});
    const origin: Origins.Origin = if (types.shared) |shared| shared.origin else .{ .source = "" };

    const identity: model.Origin = .{
        .kind = switch (origin) {
            .source => 0,
            .native => 1,
            .external => 2,
        },
        .owner = switch (origin) {
            .source, .native => |text| text,
            .external => |entry| entry.module,
        },
        .member = if (origin == .external) origin.external.member else "",
    };

    const input: model.Input = .{ .request = &selected, .shared = types.shared != null, .origins = &origins, .origin = &identity };

    const result = generated.execute(&arena, &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (result.publish) {
        const target = if (types.shared != null and result.origins.ids.len != 0) &types.shared.?.origins.items else null;
        const offsets = TypeTail.offsets(&types.items);

        const options: TypeTail.Options = .{
            .allocator = types.allocator,
            .payload = types.allocator,
            .types = &types.items,
            .origins = target,
            .offsets = &offsets,
            .text_mode = if (target != null) .OwnSharedOrigin else .Own,
        };

        var transaction: TypeTail = undefined;

        transaction.init(&options, .{}, Origins.Table{});
        errdefer transaction.release();

        const Publication = Names.TypePublication;

        const request_view = transaction.request(
            Publication,
            zx.columns.pointer(@FieldType(Publication, "delta"), result.delta),
            zx.columns.pointer(@FieldType(Publication, "origins"), result.origins),
        );

        try types.resolved.publish(types.allocator, zx.columns.pointer(*const Names.Cache, result.cache), &request_view);
    }

    if (result.diagnostic.message.len != 0) return types.reporter.fail(
        std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), result.diagnostic.code) orelse unreachable,
        .{ .start = @intCast(result.diagnostic.start), .end = @intCast(result.diagnostic.end) },
        try types.allocator.dupe(u8, result.diagnostic.message),
    );

    return @fromBackingInt(result.id);
}
