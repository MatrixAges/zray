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

    if (comptime generated) return @import("restoring/run.zig").run(module, &current, temporary, decoded);

    const allocator = current.allocator;

    if (!Seed.preflight(module, &current)) return error.InvalidModule;

    const types = current.types.view();
    const origins = current.origins.items.view().count();
    const functions = current.functions.count();

    errdefer {
        if (current.functions.count() != functions) _ = current.functions.pop(allocator);

        current.types.retainColumns(types);
        current.origins.items.retainPrefix(origins);
    }

    const binding = try rebind(module, &current, temporary);

    const tables: Tables = .{
        .types = current.types.view(),
        .functions = current.functions.view(),
        .native_modules = current.native_modules,
    };

    var restored = try materialize(module, &current, binding, tables);
    const program = &restored.program;

    if (restored.recursive != null) {
        const entry = @import("../function_body.zig").value(program.*);

        try current.functions.append(allocator, entry);

        program.functions = current.functions.view();
    }

    if (try Validate.validateProjectPrefix(temporary, program.*, current.verified.*) != null) return error.InvalidIr;

    return restored;
}

const Bound = struct {
    mapping: []const ir.TypeId,
    functions: []?ir.FunctionId,
    natives: []?ir.NativeModuleId,
    entry: ?ir.FunctionId,
};

fn rebind(module: *const model.Module, current: *const Current, temporary: std.mem.Allocator) Error!Bound {
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

const Tables = @import("../link/result/host.zig").Tables;

fn materialize(module: *const model.Module, current: *const Current, binding: Bound, tables: Tables) Error!Restored {
    var nodes = Nodes{
        .allocator = current.allocator,
        .types = .{ .mapped = binding.mapping },
        .functions = .{ .indexed = binding.functions },
        .native_modules = .{ .indexed = binding.natives },
    };

    const function = if (module.function) |value| try nodes.functionEntry(value, binding.entry, .unchecked) else null;
    const body = if (function) |*value| &value.body else null;
    const program = try @import("../link/result/host.zig").assemble(current.allocator, module, body, tables, binding.mapping);

    return .{
        .program = program,
        .recursive = if (function) |value| value.recursive else null,
    };
}
