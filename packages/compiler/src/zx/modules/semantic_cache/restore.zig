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
    const result = @import("../link/result/host.zig");
    var backup: Backup = undefined;
    var started = false;
    var staged_entry = false;
    var binding: Bound = undefined;
    var publication: Publication = undefined;

    errdefer if (started) {
        if (staged_entry) _ = current.functions.pop(payload);

        current.types.retainColumns(backup.types);
        current.origins.items.retainPrefix(backup.origins);

        if (generated) current.payloads.rewind(backup.payload);
    };

    inline for (comptime @import("restoring/steps.zig").run()) |step| {
        switch (step) {
            .Admit => {
                const valid = if (generated)
                    try @import("restoring/preflight/host.zig").check(temporary, module, &current, decoded)
                else
                    Seed.preflight(module, &current);

                if (!valid) return error.InvalidModule;

                backup = .{
                    .types = current.types.view(),
                    .origins = current.origins.items.view().count(),
                    .payload = if (generated) current.payloads.checkpoint() else {},
                };

                started = true;
            },
            .Rebind => binding = try rebind(module, &current, temporary, payload, decoded),
            .Materialize => {
                const structure: Nodes.Structure = if (decoded) .validated else .unchecked;

                const tables: result.Tables = .{
                    .types = current.types.view(),
                    .functions = current.functions.view(),
                    .native_modules = current.native_modules,
                };

                publication = try materialize(module, &current, binding, payload, tables, structure);
            },
            .StageEntry => if (publication.restored.recursive != null) {
                const program = &publication.restored.program;
                const entry = @import("../function_body.zig").value(program.*);

                if (comptime generated) {
                    try current.functions.reserve(allocator, 1);

                    current.functions.appendOwnedAssumeCapacity(entry, publication.descriptors.?);
                } else try current.functions.append(allocator, entry);

                staged_entry = true;
                program.functions = current.functions.view();
            },
            .Verify => {
                const program = &publication.restored.program;

                if (comptime generated) {
                    const verified = try @import("../../ir/canonical/validation/host.zig").verify(temporary, program, current.verified.*);
                    current.verified.* = verified orelse return error.InvalidIr;
                } else if (try Validate.validateProjectPrefix(temporary, program.*, current.verified.*) != null) return error.InvalidIr;
            },
        }
    }

    return publication.restored;
}

const Backup = struct {
    types: ir.TypeTable,
    origins: usize,
    payload: if (generated) zx.Arena.Checkpoint else void,
};

const Bound = struct {
    mapping: []const ir.TypeId,
    functions: []?ir.FunctionId,
    natives: []?ir.NativeModuleId,
    entry: ?ir.FunctionId,
};

fn rebind(module: *const model.Module, current: *const Current, temporary: std.mem.Allocator, payload: std.mem.Allocator, decoded: bool) Error!Bound {
    const allocator = current.allocator;
    const function_mapping = try temporary.alloc(?ir.FunctionId, module.functions.count() + @intFromBool(module.function != null));
    const native_mapping = try temporary.alloc(?ir.NativeModuleId, module.native_modules.count());

    @memset(function_mapping, null);
    @memset(native_mapping, null);

    const prepared: struct { mapping: []const ir.TypeId, entry: ?ir.FunctionId } = if (comptime generated) prepared: {
        const types = @import("restoring/types/host.zig");
        const ids = try temporary.alloc(u32, module.types.count());

        @memset(ids, 0);

        var workspace = zx.Arena.init(temporary);

        defer workspace.deinit();

        const plan = try types.prepare(workspace.allocator(), module, current, ids, decoded);

        const entry = try @import("restoring/rebind/host.zig").check(temporary, module, current, .{
            .types = @ptrCast(ids),
            .functions = function_mapping,
            .natives = native_mapping,
        });

        try types.commit(current, payload, plan);

        break :prepared .{ .mapping = @ptrCast(ids), .entry = entry };
    } else seed: {
        const ids = try Seed.mergeTypes(temporary, module, current);
        var nodes = Nodes{ .allocator = allocator, .types = .{ .mapped = ids }, .functions = .{ .indexed = function_mapping }, .native_modules = .{ .indexed = native_mapping } };
        const entry = try Seed.rebind(module, current, &nodes, function_mapping, native_mapping);

        break :seed .{ .mapping = ids, .entry = entry };
    };

    return .{
        .mapping = prepared.mapping,
        .functions = function_mapping,
        .natives = native_mapping,
        .entry = prepared.entry,
    };
}

const publication_host = @import("restoring/publication/host.zig");
const Publication = publication_host.Publication;
const Tables = @import("../link/result/host.zig").Tables;

fn materialize(module: *const model.Module, current: *const Current, binding: Bound, payload: std.mem.Allocator, tables: Tables, structure: Nodes.Structure) Error!Publication {
    var nodes = Nodes{
        .allocator = payload,
        .types = .{ .mapped = binding.mapping },
        .functions = .{ .indexed = binding.functions },
        .native_modules = .{ .indexed = binding.natives },
    };

    if (comptime generated) return publication_host.materialize(&nodes, module, current.path, tables, binding.entry, structure);

    const function = if (module.function) |value| try nodes.functionEntry(value, binding.entry, structure) else null;
    const body = if (function) |*value| &value.body else null;
    const program = try @import("../link/result/host.zig").assemble(current.allocator, module, body, tables, binding.mapping);

    return .{
        .restored = .{
            .program = program,
            .recursive = if (function) |value| value.recursive else null,
        },
        .descriptors = null,
    };
}
