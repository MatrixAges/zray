const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const generated = @import("parser_options").generated_parser;
const Context = @import("binding/context.zig");
const FunctionImport = @import("function_import.zig");
pub const Members = @import("binding/members.zig");
pub const Symbols = @import("binding/symbols.zig").Symbols;
pub const Selection = @import("binding/symbols.zig").Selection;

/// A caller that immediately copies the diagnostic can borrow it from the selection scope.
pub fn select(allocator: std.mem.Allocator, diagnostics: ?std.mem.Allocator, item: anytype, symbols: *const Symbols, reporter: *zx.Reporter) zx.Error!Selection {
    if (comptime !generated) return @import("binding/seed.zig").select(allocator, item, symbols, reporter);

    const rows = memory.borrowNamedRows("type_id", symbols.exports);
    var storage: @import("binding/input.zig").Storage = undefined;
    const input = storage.init(item, symbols, &rows);

    const output = @import("generated_project_binding").executeValue(allocator, input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => return reporter.fail(.contract, item.span, try std.fmt.allocPrint(diagnostics orelse allocator, "internal compiler error: generated import binding failed with {s}", .{@errorName(err)})),
    };

    if (output.message.len != 0) return reporter.fail(
        .module,
        .{ .start = @intCast(output.start), .end = @intCast(output.end) },
        if (diagnostics) |owner| try owner.dupe(u8, output.message) else output.message,
    );

    return .{
        .aliases = .{ .names = output.alias_names, .indices = output.alias_indices },
        .constants = .{ .names = output.constant_names, .indices = output.constant_indices },
        .functions = .{ .names = output.function_names, .indices = output.function_indices },
        .namespace = output.namespace,
    };
}

pub fn apply(allocator: std.mem.Allocator, temporary: std.mem.Allocator, item: anytype, context: Context, reporter: *zx.Reporter, aliases: *std.ArrayList(zx.ir.Export), imports: *std.ArrayList(FunctionImport), constants: *std.ArrayList(zx.ir.Constant)) zx.Error!void {
    const members: Members = .{ .default = if (context.default_member) |*member| member else null, .named = context.members };
    const functions = if (comptime generated) members.names() else if (item.kind == .type_only) Members.Names{} else members.names();
    const symbols = Symbols{ .target = context.target, .types = context.types, .exports = context.exports, .constants = context.constant_exports, .functions = functions };
    const selected = try select(temporary, allocator, item, &symbols, reporter);

    if (comptime generated) return publish(allocator, selected, .{ .exports = context.exports, .values = context.constant_exports, .aliases = aliases, .constants = constants }, .{ .members = members, .imports = imports });
    try publishTypes(allocator, selected, context.exports, context.constant_exports, aliases, constants);
    try publishFunctions(allocator, selected, members, imports);
}

pub fn publishTypes(allocator: std.mem.Allocator, selected: Selection, exports: []const zx.ir.Export, values: []const zx.ir.Constant, aliases: *std.ArrayList(zx.ir.Export), constants: *std.ArrayList(zx.ir.Constant)) std.mem.Allocator.Error!void {
    if (comptime generated) return publish(allocator, selected, .{ .exports = exports, .values = values, .aliases = aliases, .constants = constants }, null);
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

const Types = struct {
    exports: []const ir.Export,
    values: []const ir.Constant,
    aliases: *std.ArrayList(ir.Export),
    constants: *std.ArrayList(ir.Constant),
};

const Functions = struct { members: Members, imports: *std.ArrayList(FunctionImport) };

pub fn publish(allocator: std.mem.Allocator, selected: Selection, types: Types, functions: ?Functions) std.mem.Allocator.Error!void {
    const alias_count = selected.aliases.names.len;
    const constant_count = selected.constants.names.len;
    const function_count = if (functions != null) selected.functions.names.len else 0;

    if (alias_count + constant_count + function_count == 0) return;
    try types.aliases.ensureUnusedCapacity(allocator, alias_count);
    try types.constants.ensureUnusedCapacity(allocator, constant_count);
    if (functions) |value| try value.imports.ensureUnusedCapacity(allocator, function_count);

    const rule = @import("generated_project_binding_publication");
    const Input = std.meta.Child(rule.Input);
    const Alias = OptionalInput(Input, "aliases");
    const Constant = OptionalInput(Input, "constants");
    const Function = OptionalInput(Input, "functions");
    const Fallback = OptionalInput(Function, "fallback");
    var progress = [_]u64{ 0, 0, 0 };
    const alias_progress: []u64 = progress[0..1];
    const constant_progress: []u64 = progress[1..2];
    const function_progress: []u64 = progress[2..3];

    defer {
        types.aliases.items.len += @intCast(progress[0]);
        types.constants.items.len += @intCast(progress[1]);

        if (functions) |value| value.imports.items.len += @intCast(progress[2]);
    }

    var aliases: Alias = undefined;
    var alias_source: []const memory.NamedId = undefined;
    var alias_target: []memory.NamedId = undefined;

    if (alias_count != 0) {
        alias_source = memory.borrowNamedRows("type_id", types.exports);
        alias_target = memory.borrowNamedRows("type_id", types.aliases.unusedCapacitySlice()[0..alias_count]);
        aliases = .{ .names = selected.aliases.names, .indices = selected.aliases.indices, .source = @ptrCast(&alias_source), .target = @ptrCast(&alias_target), .written = @ptrCast(&alias_progress) };
    }

    var constants: Constant = undefined;
    var constant_source: std.meta.Child(@FieldType(Constant, "source")) = undefined;
    var constant_target: std.meta.Child(@FieldType(Constant, "target")) = undefined;
    var source_types: memory.ReadColumn = undefined;
    var source_values: memory.ReadColumn = undefined;
    var target_names: memory.WriteColumn = undefined;
    var target_types: memory.WriteColumn = undefined;
    var target_values: memory.WriteColumn = undefined;

    if (constant_count != 0) {
        const target = types.constants.unusedCapacitySlice()[0..constant_count];

        source_types = memory.borrowReadColumn(ir.TypeId, "type_id", types.values);
        source_values = memory.borrowReadColumn(ir.ConstantValue, "value", types.values);
        target_names = memory.borrowWriteColumn([]const u8, "name", target);
        target_types = memory.borrowWriteColumn(ir.TypeId, "type_id", target);
        target_values = memory.borrowWriteColumn(ir.ConstantValue, "value", target);
        constant_source = .{ .types = @ptrCast(&source_types), .values = @ptrCast(&source_values) };
        constant_target = .{ .names = @ptrCast(&target_names), .types = @ptrCast(&target_types), .values = @ptrCast(&target_values) };
        constants = .{ .names = selected.constants.names, .indices = selected.constants.indices, .source = &constant_source, .target = &constant_target, .written = @ptrCast(&constant_progress) };
    }

    var bindings: Function = undefined;
    var function_source: std.meta.Child(@FieldType(Function, "named")) = undefined;
    var function_target: std.meta.Child(@FieldType(Function, "target")) = undefined;
    var fallback: Fallback = undefined;
    var writable: FunctionImport.Writable = undefined;
    var readable: FunctionImport.Readable = undefined;

    if (function_count != 0) {
        const value = functions.?;
        readable = FunctionImport.Readable.borrowRows(value.members.named);
        function_source = readable.view(@TypeOf(function_source));
        writable = FunctionImport.Writable.borrowRows(value.imports.unusedCapacitySlice()[0..function_count]);
        function_target = writable.view(@TypeOf(function_target));

        if (value.members.default) |member| fallback = member.borrow(Fallback);

        bindings = .{ .named = &function_source, .target = &function_target, .fallback = if (value.members.default != null) &fallback else null, .namespace = selected.namespace, .names = selected.functions.names, .indices = selected.functions.indices, .written = @ptrCast(&function_progress) };
    }

    const input: Input = .{
        .aliases = if (alias_count != 0) &aliases else null,
        .constants = if (constant_count != 0) &constants else null,
        .functions = if (function_count != 0) &bindings else null,
    };

    zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

fn OptionalInput(comptime Parent: type, comptime field: []const u8) type {
    return std.meta.Child(@typeInfo(@FieldType(Parent, field)).optional.child);
}
