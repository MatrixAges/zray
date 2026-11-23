const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const generated = @import("parser_options").generated_parser;
const Context = @import("binding/context.zig");
const FunctionImport = @import("function_import.zig");
const Request = @import("binding/input.zig");
const Publisher = @import("binding/publication/host.zig");
const Reexports = @import("binding/publication/reexports.zig");
pub const Members = @import("binding/members.zig");
pub const Symbols = @import("binding/symbols.zig").Symbols;
pub const Selection = @import("binding/symbols.zig").Selection;

pub const Lists = struct {
    types: Publisher.TypeLists,
    functions: ?Publisher.FunctionList = null,
    reexports: ?Reexports.List = null,
};

/// A caller that immediately copies the diagnostic can borrow it from the selection scope.
pub fn select(allocator: std.mem.Allocator, diagnostics: ?std.mem.Allocator, item: anytype, symbols: *const Symbols, reporter: *zx.Reporter) zx.Error!Selection {
    if (comptime !generated) return @import("binding/seed.zig").select(allocator, item, symbols, reporter);

    var storage: Request.Storage = undefined;
    const input = storage.init(item, symbols);

    const output = @import("generated_project_binding").executeValue(allocator, input) catch |err|
        return bindingFailure(diagnostics orelse allocator, item.span, reporter, err);

    return readSelection(output, diagnostics, reporter);
}

pub fn deliver(allocator: std.mem.Allocator, temporary: std.mem.Allocator, item: anytype, symbols: *const Symbols, reporter: *zx.Reporter, lists: Lists) zx.Error!void {
    const rule = @import("generated_project_binding_delivery");
    const Input = std.meta.Child(rule.Input);
    var storage: Request.Storage = undefined;
    var publisher: Publisher.Publication = undefined;
    var reexports: Reexports = undefined;
    var scope: memory.ArenaScope = .{ .active = temporary };

    publisher.init(lists.types, lists.functions);
    defer publisher.commit();
    if (lists.reexports) |list| reexports.init(list);

    defer if (lists.reexports != null) reexports.commit();

    const input: Input = .{
        .request = storage.init(item, symbols),
        .destinations = &publisher.destinations,
        .reexports = if (lists.reexports != null) &reexports.input else null,
        .scope = @ptrCast(&scope),
        .owner = @ptrCast(&allocator),
    };

    const result = zx.columns.invoke(rule.executeValue, scope.allocator(), &input) catch |err|
        return bindingFailure(allocator, item.span, reporter, err);

    return reportOutcome(result, allocator, reporter);
}

fn bindingFailure(allocator: std.mem.Allocator, span: zx.Span, reporter: *zx.Reporter, err: anyerror) zx.Error {
    if (err == error.OutOfMemory or err == error.Overflow) return error.OutOfMemory;

    const message = std.fmt.allocPrint(allocator, "internal compiler error: generated import binding failed with {s}", .{@errorName(err)}) catch return error.OutOfMemory;

    return reporter.fail(.contract, span, message);
}

fn readSelection(output: anytype, diagnostics: ?std.mem.Allocator, reporter: *zx.Reporter) zx.Error!Selection {
    try reportOutcome(output, diagnostics, reporter);

    return .{
        .aliases = .{ .names = output.alias_names, .indices = output.alias_indices },
        .constants = .{ .names = output.constant_names, .indices = output.constant_indices },
        .functions = .{ .names = output.function_names, .indices = output.function_indices },
        .namespace = output.namespace,
    };
}

fn reportOutcome(output: anytype, diagnostics: ?std.mem.Allocator, reporter: *zx.Reporter) zx.Error!void {
    if (output.message.len != 0) return reporter.fail(
        .module,
        .{ .start = @intCast(output.start), .end = @intCast(output.end) },
        if (diagnostics) |owner| try owner.dupe(u8, output.message) else output.message,
    );
}

pub fn apply(allocator: std.mem.Allocator, temporary: std.mem.Allocator, item: anytype, context: Context, reporter: *zx.Reporter, aliases: *std.ArrayList(zx.ir.Export), imports: *std.ArrayList(FunctionImport), constants: *std.ArrayList(zx.ir.Constant)) zx.Error!void {
    const members: Members = .{ .default = if (context.default_member) |*member| member else null, .named = context.members };
    const functions = if (comptime generated) members.names() else if (item.kind == .type_only) Members.Names{} else members.names();
    const symbols = Symbols{ .target = context.target, .types = context.types, .exports = context.exports, .constants = context.constant_exports, .functions = functions };

    if (comptime generated) {
        return deliver(allocator, temporary, item, &symbols, reporter, .{
            .types = .{ .exports = context.exports, .values = context.constant_exports, .aliases = aliases, .constants = constants },
            .functions = .{ .members = members, .imports = imports },
        });
    }

    const selected = try select(temporary, allocator, item, &symbols, reporter);

    try publishTypes(allocator, selected, context.exports, context.constant_exports, aliases, constants);
    try publishFunctions(allocator, selected, members, imports);
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

pub fn publishFunctions(allocator: std.mem.Allocator, selected: Selection, members: Members, imports: *std.ArrayList(FunctionImport)) std.mem.Allocator.Error!void {
    const namespace = if (selected.functions.names.len != 0 and selected.namespace != null) try allocator.dupe(u8, selected.namespace.?) else null;

    try imports.ensureUnusedCapacity(allocator, selected.functions.names.len);

    for (selected.functions.names, selected.functions.indices) |name, index| {
        var imported = members.at(@intCast(index)).*;
        imported.name = try allocator.dupe(u8, name);
        imported.namespace = namespace;

        imports.appendAssumeCapacity(imported);
    }
}
