const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Native = @import("../../interface.zig").Native;
const Loaded = @import("../../native.zig");
const Origins = @import("../../nominal_origins.zig");
const Project = @import("../../project.zig").Project;
const signatures = @import("../../link/signature/publication/host.zig");
const destination = @import("../../link/signature/publication/destination.zig");
const TypeTail = @import("../../../analysis/semantic/merging/publication/view.zig");
const generated = @import("generated_native_interface_delivery");
const Input = std.meta.Child(generated.Input);
const Members = std.meta.Child(@FieldType(Input, "members"));

pub fn load(project: *Project, entry: *const Native, module: ir.NativeModuleId, span: zx.Span) zx.Error!Loaded.Result {
    const allocator = project.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    var scope: zx.memory.ArenaScope = .{ .active = scratch.allocator() };
    var types: TypeTail = undefined;
    const offsets = TypeTail.offsets(&project.types);
    const owner = project.native_modules.view().at(@backingInt(module)).key();
    const options: TypeTail.Options = .{ .allocator = allocator, .payload = allocator, .types = &project.types, .origins = &project.nominal_origins.items, .offsets = &offsets, .native_owner = owner };

    types.init(&options, .{}, Origins.Table{});

    errdefer types.release();

    var members: signatures.Stage(Members) = undefined;

    members.init(&allocator, &project.functions);

    var exports: []zx.memory.NamedId = &.{};
    var names: []const []const u8 = &.{};
    var ids: []const u32 = &.{};
    const slots = zx.memory.borrowColumnLengths(&project.functions);
    const lengths: zx.memory.ColumnLengths = &slots;

    const input: Input = .{
        .source = entry.source,
        .namespace_bytes = entry.namespace,
        .base = &ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "base")), project.types.view()),
        .origins = &Origins.Table.borrow(std.meta.Child(@FieldType(Input, "origins")), project.nominal_origins.items.view()),
        .owner = &.{ .path = entry.path, .namespace = entry.namespace, .module = @backingInt(module) },
        .owner_key = owner,
        .scope = @ptrCast(&scope),
        .payload = @ptrCast(&allocator),
        .types = zx.columns.pointer(@FieldType(Input, "types"), @as(*const TypeTail.Target, &types.target)),
        .exports = @ptrCast(&exports),
        .bindings = &.{ .names = @ptrCast(&names), .ids = @ptrCast(&ids) },
        .members = &.{
            .destination = &members.functions.input,
            .members = &members.output.view,
            .member_storage = @ptrCast(&members.output.buffer),
            .first = project.functions.count(),
            .empty = &destination.empty(std.meta.Child(@FieldType(Members, "empty"))),
        },
        .native = &.{
            .module = @backingInt(module),
            .namespaces = @ptrCast(&project.native_modules.type_namespaces.items),
            .type_names = @ptrCast(&project.native_modules.type_names.items),
            .type_ids = @ptrCast(&project.native_modules.type_ids.items),
            .functions = @ptrCast(&lengths),
        },
    };

    const status = generated.executeIn(scope.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return fail(project, entry, span, .contract, 0, try std.fmt.allocPrint(scratch.allocator(), "internal compiler error: generated native {s} failed with {s}", .{ if (scope.active.ptr == allocator.ptr) "delivery" else "analysis", @errorName(err) })),
    };

    if (status.message.len != 0) return fail(project, entry, span, std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), status.code) orelse unreachable, @intCast(status.start), status.message);

    return .{ .types = project.types.view(), .exports = @ptrCast(exports), .members = members.members() };
}

fn fail(project: *Project, entry: *const Native, span: zx.Span, code: @FieldType(zx.Diagnostic, "code"), offset: usize, cause: []const u8) zx.Error {
    const location = zx.source.locate(entry.source, offset);
    const message = std.fmt.allocPrint(project.allocator, "{s}:{d}:{d}: {s}", .{ entry.path, location.line, location.column, cause }) catch return error.OutOfMemory;

    return project.reporter.fail(code, span, message);
}
