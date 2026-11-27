const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const project_api = @import("../../project.zig");
const ModuleRecord = @import("../../module_record.zig");
const Project = project_api.Project;
const LoadFrame = project_api.LoadFrame;
const Unit = project_api.Unit;
const Inputs = @import("../../module_input.zig");
const indexed = @import("../../parse_cache.zig").indexed_enabled;
const publication = @import("../publication/host.zig");
const exports = @import("../../public_exports.zig");
const restore = @import("../../semantic_cache/restore.zig");
const cache_entries = @import("../../semantic_cache/entries.zig");
const errorSet = @import("invoke.zig").errorSet;
const generated = @import("parser_options").generated_parser;

const Body = struct {
    project: *Project,
    frame: *LoadFrame,
    unit: *Unit,
    entry: bool,
    first_type: usize,
    declared: bool,
    check_ownership: bool,
    restored: ?restore.Restored = null,
    program: ir.Program = undefined,
    installation: if (generated) @import("body_install/host.zig") else void = undefined,
    exports: if (generated) @import("body_exports/host.zig") else void = undefined,
    fn borrow(handle: *anyopaque) *Body {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn run(project: *Project, frame: *LoadFrame, input: anytype) zx.Error!void {
    const unit = &project.units[frame.index];

    var body: Body = .{
        .project = project,
        .frame = frame,
        .unit = unit,
        .entry = std.mem.eql(u8, unit.path, project.options.entry),
        .first_type = project.types.count(),
        .declared = input.header().functionName() != null,
        .check_ownership = !@TypeOf(input).completes_ownership,
    };

    if (comptime generated) {
        const entry = @import("generated_project_execute_body");
        var scratch = std.heap.ArenaAllocator.init(project.arena.child_allocator);

        defer scratch.deinit();

        body.exports.scratch = scratch.allocator();

        body.installation.bind(project);
        defer body.installation.commit();

        const cache = project.semantic_cache;
        const usage: zx.memory.ColumnLengths = if (cache) |store| &.{ &store.analyzed, &store.reused } else &.{};

        const request: std.meta.Child(entry.Input) = .{
            .body = @ptrCast(&body),
            .cache = if (cache) |store| &.{
                .body = @ptrCast(&body),
                .root = body.entry,
                .dependency_ready = project.cache_context.dependency_ready,
                .lookup = &.{
                    .entries = @ptrCast(&store.entries),
                    .path = unit.path,
                    .source = &frame.parsed.digest,
                    .context = if (body.entry) &project.cache_context.root else &project.cache_context.dependency,
                },
                .usage = @ptrCast(&usage),
            } else null,
            .exports = &body.exports.input,
            .installation = &body.installation.input,
        };

        const outcome = zx.columns.invoke(entry.executeIn, project.allocator, &request) catch |err| return switch (@as(anyerror, err)) {
            error.IntegerOverflow, error.Overflow => error.OutOfMemory,
            else => errorSet(err),
        };

        if (outcome.records_used) |count| body.installation.modules.length = count;
        if (outcome.cache_used) |count| body.installation.cache.length = count;
        if (outcome.duplicate) |name| return exports.reportDuplicate(project.allocator, project.reporter, name);
        if (outcome.cache_root) |root| project.cache_root = @intCast(root);

        return;
    }

    return seed(&body, input);
}

fn seed(body: *Body, input: anytype) zx.Error!void {
    const project = body.project;
    var restored = false;

    if (project.semantic_cache) |cache| {
        const context = &project.cache_context;

        const digest = if (!body.entry and context.dependency_ready)
            &context.dependency

        else
            try context.compute(project.allocator, if (body.entry) project.options.context else null);

        if (cache_entries.find(&cache.entries, body.unit.path, &body.frame.parsed.digest, digest)) |candidate| {
            restored = try restoreCachedProjectBody(body, candidate);
        }

        if (restored) cache.reused += 1 else cache.analyzed += 1;
    }

    if (!restored) try analyze(body, input);

    const plan = try publication.module(&body.program, .{
        .entry = body.entry,
        .declared = body.declared,
        .linked = project.functions.count(),
        .restored = if (body.restored) |*value| value else null,
        .check_ownership = body.check_ownership,
        .cache = project.semantic_cache != null,
    });

    body.unit.function = plan.id;

    if (plan.append) try project.functions.append(project.allocator, @import("../../function_body.zig").value(body.program));
    if (plan.ownership_count) |count| try checkProjectOwnership(body, count, if (plan.id) |id| @backingInt(id) else null);
    try publishSeedExports(body);

    if (plan.publish_artifact) {
        const index = project.modules.items.len;

        try project.cache_records.append(project.arena.child_allocator, index);
        if (body.entry) project.cache_root = index;
    }

    try project.modules.append(project.allocator, record(body, plan.body, plan.own_function));
    if (body.entry) moveProjectEntryBody(body);
}

pub fn hashProjectCacheContext(handle: *anyopaque, root: bool) std.mem.Allocator.Error!void {
    const project = Body.borrow(handle).project;
    _ = try project.cache_context.compute(project.allocator, if (root) project.options.context else null);
}

pub fn restoreCachedProjectBody(handle: *anyopaque, entry: *anyopaque) std.mem.Allocator.Error!bool {
    const self = Body.borrow(handle);
    const project = self.project;
    const frame = self.frame;
    const path = self.unit.path;
    const cached: *const cache_entries.Entry = @ptrCast(@alignCast(entry));

    self.restored = try restore.restore(cached, .{
        .allocator = project.allocator,
        .backing = project.arena.child_allocator,
        .payloads = project.restored_payloads.?,
        .types = &project.types,
        .origins = &project.nominal_origins,
        .functions = &project.functions,
        .verified = &project.verified,
        .native_modules = project.native_modules.view(),
        .aliases = frame.aliases.items,
        .imports = frame.imports.items,
        .members = frame.export_functions.items,
        .constant_imports = frame.constant_imports.items,
        .dependencies = frame.dependencies.items,
        .path = path,
    });

    if (self.restored) |*value| {
        self.program = value.program;

        if (comptime generated) preparePlan(self);

        return true;
    }

    return false;
}

pub fn analyzeProjectBody(handle: *anyopaque) zx.Error!void {
    const body = Body.borrow(handle);

    try switch (body.frame.parsed.result.*) {
        .native => |result| analyze(body, Inputs.Native{ .value = result.value.parsed }),
        .indexed => |*result| if (indexed) analyze(body, Inputs.Indexed{ .value = result }) else unreachable,
    };

    if (comptime generated) preparePlan(body);
}

fn analyze(body: *Body, input: anytype) zx.Error!void {
    const project = body.project;
    const frame = body.frame;
    const path = body.unit.path;
    const context = @import("../../../analysis/analyzer/host/context.zig");

    var analyzer: context = .{
        .allocator = project.allocator,
        .reporter = project.reporter,
        .mode = .project,
        .base_types = project.types.view(),
        .base_origins = project.nominal_origins.items.view(),
        .native_modules = project.native_modules.view(),
        .types = &project.types,
        .aliases = frame.aliases.items,
        .origins = &project.nominal_origins,
        .origin = .{ .source = path },
        .function_imports = frame.imports.items,
        .constant_imports = frame.constant_imports.items,
        .functions = project.functions.view(),
        .store_bindings = if (body.entry) project.options.context.stores else &.{},
        .store_type_count = project.options.context.types.count(),
    };

    body.program = try input.analyze(&analyzer, path);
}

fn preparePlan(body: *Body) void {
    const project = body.project;
    const restored = if (body.restored) |value| value.recursive else null;

    body.installation.request = .{
        .type_only = body.program.type_only,
        .entry = body.entry,
        .declared = body.declared,
        .restored = body.restored != null,
        .restored_function = if (restored) |id| @backingInt(id) else null,
        .check_ownership = body.check_ownership,
        .cache = project.semantic_cache != null,
        .linked_count = project.functions.count(),
        .calls = body.program.expressions.call_functions,
    };
}

pub fn materializeProjectFunction(handle: *anyopaque) std.mem.Allocator.Error!void {
    const body = Body.borrow(handle);

    try body.installation.ownFunction(body.project.allocator, &body.program);
}

pub fn bindProjectBodyExports(handle: *anyopaque, id: ?u32) void {
    const body = Body.borrow(handle);

    body.exports.bind(&body.program, body.frame, if (id) |value| @fromBackingInt(value) else null);
}

pub fn checkProjectOwnership(handle: *anyopaque, count: u64, id: ?u32) zx.Error!void {
    const body = Body.borrow(handle);
    const project = body.project;
    const program = &body.program;
    program.functions = project.functions.view().prefix(@intCast(count));
    program.output_ownership = try @import("../../../ownership/check.zig").analyze(project.allocator, program.*, project.reporter);

    if (id) |index| project.functions.ownership.items[index] = switch (program.output_ownership) {
        .copy => .Copy,
        .borrowed => .Borrowed,
        .owned => .Owned,
    };
}

fn publishSeedExports(body: *Body) zx.Error!void {
    const project = body.project;
    const frame = body.frame;
    const program = &body.program;
    const unit = body.unit;
    const own: ?project_api.FunctionImport = if (unit.function) |id| .{ .name = "", .id = id, .input_type = program.input_type, .output_type = program.output_type } else null;
    unit.exports = try exports.merge(ir.Export, project.allocator, program.exports, frame.export_aliases.items);
    unit.constants = try exports.merge(ir.Constant, project.allocator, program.constant_exports, frame.export_constants.items);
    unit.members = try exports.prepend(project_api.FunctionImport, project.allocator, own, frame.export_functions.items);

    if (frame.export_aliases.items.len + frame.export_constants.items.len + frame.export_functions.items.len != 0) {
        unit.function = try exports.bodyEntry(project.allocator, project.arena.child_allocator, unit.function, unit.exports, unit.constants, unit.members, project.reporter);
    }
}

pub fn writeProjectModuleRecord(handle: *anyopaque, row: u64, types: []const u8, constants: []const u8, members: []const u8, entry: ?u32, entry_record: bool, function_id: ?u32, recursive: ?u32) void {
    const body = Body.borrow(handle);
    const rows = @import("../exports/publication/rows.zig");
    const unit = body.unit;

    unit.exports = rows.typedRows(ir.Export, types);
    unit.constants = rows.typedRows(ir.Constant, constants);
    unit.members = rows.typedRows(project_api.FunctionImport, members);
    unit.function = if (entry) |id| @fromBackingInt(id) else null;

    const kind: @FieldType(ModuleRecord, "body") = if (entry_record)
        .entry

    else if (function_id) |id|
        .{ .function = @fromBackingInt(id) }
    else
        .types;

    body.installation.modules.output.rows()[@intCast(row)] = record(body, kind, if (recursive) |id| @fromBackingInt(id) else null);
}

inline fn record(body: *const Body, kind: @FieldType(ModuleRecord, "body"), recursive: ?ir.FunctionId) ModuleRecord {
    const frame = body.frame;
    const program = &body.program;

    return .{
        .path = body.unit.path,
        .source_digest = frame.parsed.digest,
        .type_range = .{ .start = body.first_type, .end = program.types.count() },
        .exports = program.exports,
        .constant_exports = program.constant_exports,
        .reexports = .{ .types = frame.export_aliases.items, .constants = frame.export_constants.items, .functions = frame.export_functions.items },
        .constant_imports = frame.constant_imports.items,
        .imports = frame.dependencies.items,
        .type_imports = frame.aliases.items,
        .function_imports = frame.imports.items,
        .body = kind,
        .own_function = recursive,
    };
}

pub fn moveProjectEntryBody(handle: *anyopaque) void {
    const body = Body.borrow(handle);
    const program = &body.program;
    program.types = .{};
    program.functions = .{};
    body.project.entry_program = program.*;
}
