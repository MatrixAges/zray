const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const Context = @import("binding/context.zig");
const FunctionImport = @import("function_import.zig");
pub const Request = @import("binding/input.zig");
const Publisher = @import("binding/publication/host.zig");
const Reexports = @import("binding/publication/reexports.zig");
pub const Members = @import("binding/members.zig");
pub const Symbols = @import("binding/symbols.zig").Symbols;
const Selection = @import("binding/symbols.zig").Selection;
pub const selectSeed = @import("binding/seed.zig").select;

pub const Lists = struct {
    types: Publisher.TypeLists,
    functions: ?Publisher.FunctionList = null,
    reexports: ?Reexports.List = null,
};

pub fn deliver(allocator: std.mem.Allocator, temporary: std.mem.Allocator, item: anytype, symbols: *const Symbols, reporter: *zx.Reporter, lists: Lists) zx.Error!void {
    const rule = @import("generated_project_binding_delivery");
    const Input = std.meta.Child(rule.Input);
    var storage: Request.Storage = undefined;
    var publisher: Publisher.Publication = undefined;
    var reexports: Reexports = undefined;

    publisher.init(lists.types, lists.functions);

    if (lists.reexports) |list| reexports.init(list, allocator);

    defer if (lists.reexports != null) reexports.settle();
    errdefer if (lists.reexports != null) reexports.discard();

    const input: Input = .{
        .request = storage.init(item, symbols),
        .destinations = &publisher.destinations,
        .reexports = if (lists.reexports != null) &reexports.input else null,
    };

    const result = rule.executeIn(temporary, &input, &reexports) catch |err|
        return bindingFailure(allocator, item.span, reporter, err);

    if (result.message.len != 0) return reporter.fail(
        .module,
        .{ .start = @intCast(result.start), .end = @intCast(result.end) },
        try allocator.dupe(u8, result.message),
    );

    if (result.aliases.len != 0) {
        try lists.types.aliases.ensureUnusedCapacity(allocator, result.aliases.len);

        for (result.aliases) |row| {
            lists.types.aliases.appendAssumeCapacity(.{
                .name = try allocator.dupe(u8, row.name),
                .type_id = @fromBackingInt(row.type_id),
            });
        }
    }

    if (result.constants.len != 0) {
        try lists.types.constants.ensureUnusedCapacity(allocator, result.constants.len);

        for (result.constants) |row| {
            var constant = lists.types.values[@intCast(row.index)];

            constant.name = try allocator.dupe(u8, row.name);

            if (constant.value == .string) constant.value.string = try allocator.dupe(u8, constant.value.string);

            lists.types.constants.appendAssumeCapacity(constant);
        }
    }

    if (lists.functions) |function_list| {
        if (result.functions.len != 0) {
            const namespace = if (result.functions[0].namespace) |text| try allocator.dupe(u8, text) else null;

            try function_list.imports.ensureUnusedCapacity(allocator, result.functions.len);

            for (result.functions) |row| {
                function_list.imports.appendAssumeCapacity(.{
                    .namespace = namespace,
                    .name = try allocator.dupe(u8, row.name),
                    .id = if (row.id) |id| @fromBackingInt(id) else null,
                    .input_type = if (row.input_type) |id| @fromBackingInt(id) else null,
                    .output_type = if (row.output_type) |id| @fromBackingInt(id) else null,
                    .intrinsic = if (row.intrinsic) |operation| @fromBackingInt(operation) else null,
                });
            }
        }
    }

    if (lists.reexports != null) {
        if (result.reexports) |count| reexports.tail.length = count;
    }
}

fn bindingFailure(allocator: std.mem.Allocator, span: zx.Span, reporter: *zx.Reporter, err: anyerror) zx.Error {
    if (err == error.OutOfMemory or err == error.Overflow) return error.OutOfMemory;

    const message = std.fmt.allocPrint(allocator, "internal compiler error: generated import binding failed with {s}", .{@errorName(err)}) catch return error.OutOfMemory;

    return reporter.fail(.contract, span, message);
}

pub fn applySeed(allocator: std.mem.Allocator, temporary: std.mem.Allocator, item: anytype, context: Context, reporter: *zx.Reporter, aliases: *std.ArrayList(zx.ir.Export), imports: *std.ArrayList(FunctionImport), constants: *std.ArrayList(zx.ir.Constant)) zx.Error!void {
    const members: Members = .{ .default = if (context.default_member) |*member| member else null, .named = context.members };
    const functions = if (item.kind == .type_only) Members.Names{} else members.names();
    const symbols = Symbols{ .target = context.target, .types = context.types, .exports = context.exports, .constants = context.constant_exports, .functions = functions };
    const selected = try selectSeed(temporary, item, &symbols, reporter);

    try publishTypes(allocator, selected, context.exports, context.constant_exports, aliases, constants);
    try publishSeedFunctions(allocator, selected, members, imports, &.{}, false);
}

pub fn publishTypes(allocator: std.mem.Allocator, selected: Selection, exports: []const zx.ir.Export, values: []const zx.ir.Constant, aliases: *std.ArrayList(zx.ir.Export), constants: *std.ArrayList(zx.ir.Constant)) std.mem.Allocator.Error!void {
    try aliases.ensureUnusedCapacity(allocator, selected.aliases.names.len);

    for (selected.aliases.names, selected.aliases.indices) |name, index| {
        aliases.appendAssumeCapacity(.{ .name = try allocator.dupe(u8, name), .type_id = exports[@intCast(index)].type_id });
    }

    try constants.ensureUnusedCapacity(allocator, selected.constants.names.len);

    for (selected.constants.names, selected.constants.indices) |name, index| {
        var constant = values[@intCast(index)];

        constant.name = try allocator.dupe(u8, name);

        if (constant.value == .string) constant.value.string = try allocator.dupe(u8, constant.value.string);

        constants.appendAssumeCapacity(constant);
    }
}

pub fn publishSeedFunctions(allocator: std.mem.Allocator, selected: Selection, members: Members, imports: *std.ArrayList(FunctionImport), prefix: []const FunctionImport, preserve_namespace: bool) std.mem.Allocator.Error!void {
    const namespace = if (!preserve_namespace and selected.functions.names.len != 0 and selected.namespace != null) try allocator.dupe(u8, selected.namespace.?) else null;
    const count = std.math.add(usize, prefix.len, selected.functions.names.len) catch return error.OutOfMemory;

    try imports.ensureUnusedCapacity(allocator, count);

    imports.appendSliceAssumeCapacity(prefix);

    for (selected.functions.names, selected.functions.indices) |name, index| {
        var imported = members.at(@intCast(index)).*;

        imported.name = try allocator.dupe(u8, name);

        if (!preserve_namespace) imported.namespace = namespace;

        imports.appendAssumeCapacity(imported);
    }
}
