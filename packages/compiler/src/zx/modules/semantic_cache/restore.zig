const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const model = @import("../artifact/model.zig");
const Nodes = @import("../artifact/nodes.zig");
const Origins = @import("../nominal_origins.zig");
const Record = @import("../module_record.zig");
const FunctionImport = @import("../function_import.zig");
const generated = @import("parser_options").generated_parser;
const Seed = @import("restoring/seed.zig");
const Validate = @import("../../ir/validate.zig");

pub const Current = struct {
    allocator: std.mem.Allocator,
    backing: std.mem.Allocator,
    payloads: *zx.Arena,
    types: *ir.TypeStorage,
    origins: *Origins,
    functions: *ir.FunctionStorage,
    verified: *Validate.Verified,
    native_modules: ir.NativeModuleTable,
    aliases: []const ir.Export,
    imports: []const FunctionImport,
    members: []const FunctionImport = &.{},
    constant_imports: []const ir.Constant = &.{},
    dependencies: []const Record.Import,
    path: []const u8,
};

const Error = @import("../link/types.zig").Error || model.Error;

pub const Restored = struct {
    program: ir.Program,
    recursive: ?ir.FunctionId,
};

pub fn restore(entry: *const @import("entries.zig").Entry, current: Current) std.mem.Allocator.Error!?Restored {
    return restoreChecked(&entry.result.value, current, generated and entry.decoded) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return null;
    };
}

fn restoreChecked(module: *const model.Module, current: Current, decoded: bool) Error!Restored {
    var arena = std.heap.ArenaAllocator.init(current.backing);
    var buffer: [2048]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const temporary = scratch.allocator();
    const allocator = current.allocator;
    const payload = if (generated) current.payloads.allocator() else allocator;

    const valid = if (generated)
        try @import("restoring/preflight/host.zig").check(temporary, module, &current, decoded)
    else
        Seed.preflight(module, &current);

    if (!valid) return error.InvalidModule;

    const backup: Backup = .{
        .types = current.types.view(),
        .origins = current.origins.items.view().count(),
        .functions = current.functions.count(),
        .payload = if (generated) current.payloads.checkpoint() else {},
    };

    errdefer {
        if (current.functions.count() != backup.functions) {
            if (comptime generated) {
                current.functions.retainPrefix(backup.functions);
            } else _ = current.functions.pop(payload);
        }

        current.types.retainColumns(backup.types);
        current.origins.items.retainPrefix(backup.origins);

        if (generated) current.payloads.rewind(backup.payload);
    }

    const binding = try rebind(module, &current, temporary, payload, decoded);
    const structure: Nodes.Structure = if (decoded) .validated else .unchecked;

    const tables: Tables = .{
        .types = current.types.view(),
        .functions = current.functions.view(),
        .native_modules = current.native_modules,
    };

    var restored = try materialize(module, &current, binding, payload, tables, structure);
    const program = &restored.program;

    if (!generated and restored.recursive != null) {
        const entry = @import("../function_body.zig").value(program.*);

        try current.functions.append(allocator, entry);

        program.functions = current.functions.view();
    }

    if (comptime generated) {
        const verified = try @import("../../ir/canonical/validation/host.zig").verify(temporary, program, current.verified.*);

        current.verified.* = verified orelse return error.InvalidIr;
    } else if (try Validate.validateProjectPrefix(temporary, program.*, current.verified.*) != null) return error.InvalidIr;

    return restored;
}

const Backup = struct {
    types: ir.TypeTable,
    origins: usize,
    functions: usize,
    payload: if (generated) zx.Arena.Checkpoint else void,
};

const Bound = struct {
    mapping: []const ir.TypeId,
    functions: []?ir.FunctionId,
    natives: []?ir.NativeModuleId,
    entry: ?ir.FunctionId,
};

fn rebind(module: *const model.Module, current: *const Current, temporary: std.mem.Allocator, payload: std.mem.Allocator, decoded: bool) Error!Bound {
    if (comptime generated) {
        const types = @import("restoring/types/host.zig");
        var maps: @import("restoring/rebind/host.zig").Maps = .{ .allocator = temporary };
        var workspace = zx.Arena.init(temporary);

        defer workspace.deinit();

        const plan = try types.prepare(workspace.allocator(), module, current, &maps, decoded);

        try types.commit(current, payload, plan.types);

        return .{
            .mapping = @ptrCast(maps.types),
            .functions = maps.functions,
            .natives = maps.natives,
            .entry = plan.entry,
        };
    }

    const allocator = current.allocator;
    const function_mapping = try temporary.alloc(?ir.FunctionId, module.functions.count() + @intFromBool(module.function != null));
    const native_mapping = try temporary.alloc(?ir.NativeModuleId, module.native_modules.count());

    @memset(function_mapping, null);
    @memset(native_mapping, null);

    const ids = try Seed.mergeTypes(temporary, module, current);
    var nodes = Nodes{ .allocator = allocator, .types = .{ .mapped = ids }, .functions = .{ .indexed = function_mapping }, .native_modules = .{ .indexed = native_mapping } };
    const entry = try Seed.rebind(module, current, &nodes, function_mapping, native_mapping);

    return .{
        .mapping = ids,
        .functions = function_mapping,
        .natives = native_mapping,
        .entry = entry,
    };
}

const publication_host = @import("restoring/publication/host.zig");
const Tables = @import("../link/result/host.zig").Tables;

fn materialize(module: *const model.Module, current: *const Current, binding: Bound, payload: std.mem.Allocator, tables: Tables, structure: Nodes.Structure) Error!Restored {
    var nodes = Nodes{
        .allocator = payload,
        .types = .{ .mapped = binding.mapping },
        .functions = .{ .indexed = binding.functions },
        .native_modules = .{ .indexed = binding.natives },
    };

    if (comptime generated) return publication_host.materialize(&nodes, module, .{
        .allocator = current.allocator,
        .functions = current.functions,
        .tables = tables,
        .path = current.path,
    }, binding.entry, structure);

    const function = if (module.function) |value| try nodes.functionEntry(value, binding.entry, structure) else null;
    const body = if (function) |*value| &value.body else null;
    const program = try @import("../link/result/host.zig").assemble(current.allocator, module, body, tables, binding.mapping);

    return .{
        .program = program,
        .recursive = if (function) |value| value.recursive else null,
    };
}
