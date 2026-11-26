const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Native = @import("../../interface.zig").Native;
const Artifact = @import("../../artifact/model.zig");
const Origins = @import("../../nominal_origins.zig");
const FunctionImport = @import("../../function_import.zig");
const columns = @import("../../artifact/materializing/publication/columns.zig");
const TypeTail = @import("../../../analysis/semantic/merging/publication/view.zig");
const generated = @import("generated_native_artifact");
const publishing = @import("generated_native_artifact_publish");
const Input = std.meta.Child(generated.Input);
const PublishInput = std.meta.Child(publishing.Input);
const Targets = std.meta.Child(@FieldType(PublishInput, "targets"));
const SignatureRow = @import("project_execution_abi").layouts.@"zig:memory/columns".SignatureRow;

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
    var type_tail: TypeTail = undefined;
    const options: TypeTail.Options = .{ .allocator = payload, .payload = payload, .types = &types, .origins = null, .precise = true };

    type_tail.init(&options, .{}, Origins.Table{});

    var exports: []const zx.memory.NamedId = &.{};
    var bindings: FunctionImport.Output(std.meta.Child(@FieldType(Targets, "binding_target"))) = undefined;

    bindings.init();

    var signatures: ir.SignatureStorage = .{};
    var signature_tails: ir.SignatureTable = .{};
    var ranges = zx.memory.bindColumnRanges(&signatures, @as(ir.SignatureTable, .{}), &signature_tails);
    var signature_ranges: zx.memory.ColumnRanges = &ranges;
    const slots = zx.memory.bindColumnSet(SignatureRow, true, &signatures);
    const signature_target: zx.memory.ColumnSet = &slots;

    const targets: Targets = .{
        .payload = @ptrCast(&payload),
        .types = zx.columns.pointer(@FieldType(Targets, "types"), @as(*const TypeTail.Target, &type_tail.target)),
        .signature_target = @ptrCast(&signature_target),
        .signature_ranges = @ptrCast(&signature_ranges),
        .binding_target = &bindings.view,
        .binding_storage = @ptrCast(&bindings.buffer),
        .export_target = @ptrCast(&exports),
    };

    const publish_input: PublishInput = .{
        .declaration = &declaration,
        .key = key,
        .types = try zx.columns.bridge(@FieldType(PublishInput, "types"), temp, artifact.types),
        .origins = try zx.columns.bridge(@FieldType(PublishInput, "origins"), temp, artifact.origins),
        .exports = try zx.columns.bridge(@FieldType(PublishInput, "exports"), temp, artifact.exports),
        .members = try zx.columns.bridge(@FieldType(PublishInput, "members"), temp, artifact.members),
        .targets = &targets,
    };

    const value = publishing.executeIn(payload, &publish_input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return .{ .arena = arena, .value = .{
        .path = value.path,
        .source_digest = fingerprint,
        .types = types.view(),
        .nominal_types = columns.view(Origins.Table, value.origins),
        .exports = @ptrCast(exports),
        .function_imports = bindings.rows(),
        .functions = signatures.view(),
        .native_modules = columns.view(ir.NativeModuleTable, value.modules),
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
