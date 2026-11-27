const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Native = @import("../../interface.zig").Native;
const Artifact = @import("../../artifact/model.zig");
const Origins = @import("../../nominal_origins.zig");
const publication = @import("../../native/publication/host.zig");
const TypeTail = @import("../../../analysis/semantic/merging/publication/view.zig");
const generated = @import("generated_native_artifact");
const publishing = @import("generated_native_artifact_publish");
const Input = std.meta.Child(generated.Input);
const PublishInput = std.meta.Child(publishing.Input);

pub fn create(allocator: std.mem.Allocator, entry: Native, fingerprint: [32]u8, error_allocator: std.mem.Allocator, reporter: *zx.Reporter, span: zx.Span) zx.Error!Artifact.Result {
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const temp = scratch.allocator();
    const base = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "base")), .{});
    const origins = Origins.Table.borrow(std.meta.Child(@FieldType(Input, "origins")), .{});
    const key = entry.key();

    const input: Input = .{
        .key = key,
        .namespace_bytes = entry.namespace,
        .source = entry.source,
        .base = &base,
        .origins = &origins,
    };

    const result = generated.executeIn(temp, &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return fail(error_allocator, reporter, entry, span, .contract, 0, try std.fmt.allocPrint(temp, "internal compiler error: generated native analysis failed with {s}", .{@errorName(err)})),
    };

    const artifact = result.artifact orelse return fail(error_allocator, reporter, entry, span, std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), result.diagnostic.code) orelse unreachable, @intCast(result.diagnostic.start), result.diagnostic.message);
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const payload = arena.allocator();

    const declaration: std.meta.Child(@FieldType(PublishInput, "declaration")) = .{
        .identity = entry.identity,
        .specifier = entry.specifier,
        .path = entry.path,
        .import_name = entry.module,
        .namespace = entry.namespace,
    };

    var types: ir.TypeStorage = .{};
    var nominal: Origins.Storage = .{};
    var type_tail: TypeTail = undefined;
    const options: TypeTail.Options = .{ .allocator = payload, .payload = payload, .types = &types, .origins = &nominal, .precise = true };

    type_tail.init(options);

    const publish_input: PublishInput = .{
        .declaration = &declaration,
        .key = key,
        .types = try zx.columns.bridge(@FieldType(PublishInput, "types"), temp, artifact.types),
        .origins = try zx.columns.bridge(@FieldType(PublishInput, "origins"), temp, artifact.origins),
        .exports = try zx.columns.bridge(@FieldType(PublishInput, "exports"), temp, artifact.exports),
        .members = try zx.columns.bridge(@FieldType(PublishInput, "members"), temp, artifact.members),
        .target = zx.columns.pointer(@FieldType(PublishInput, "target"), @as(*const TypeTail.Target, &type_tail.target)),
    };

    const value = publishing.executeIn(payload, &publish_input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    try type_tail.commit(value.publication);

    const exports = try payload.alloc(ir.Export, value.exports.names.len);
    const bindings = try publication.ownBindings(payload, value.members.bindings);
    var signatures: ir.SignatureStorage = .{};

    for (value.exports.names, value.exports.ids, exports) |name, id, *slot| {
        slot.* = .{ .name = name, .type_id = @fromBackingInt(id) };
    }

    inline for (@typeInfo(ir.SignatureStorage).@"struct".field_names) |name| {
        try @field(signatures, name).ensureTotalCapacityPrecise(payload, value.members.signatures.len);
    }

    publication.appendColumnsAssumeCapacity(&signatures, value.members.signatures);

    return .{ .arena = arena, .value = .{
        .path = value.path,
        .source_digest = fingerprint,
        .types = types.view(),
        .nominal_types = nominal.view(),
        .exports = exports,
        .function_imports = bindings,
        .functions = signatures.view(),
        .native_modules = zx.columns.view(ir.NativeModuleTable, value.modules),
        .dependencies = &.{},
        .type_imports = &.{},
        .function = null,
        .stores = .{},
    } };
}

fn fail(allocator: std.mem.Allocator, reporter: *zx.Reporter, entry: Native, span: zx.Span, code: @FieldType(zx.Diagnostic, "code"), offset: usize, cause: []const u8) zx.Error {
    const location = zx.source.locate(entry.source, offset);
    const message = std.fmt.allocPrint(allocator, "{s}:{d}:{d}: {s}", .{ entry.path, location.line, location.column, cause }) catch return error.OutOfMemory;

    return reporter.fail(code, span, message);
}
