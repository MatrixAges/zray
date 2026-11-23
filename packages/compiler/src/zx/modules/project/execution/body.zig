const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const project_api = @import("../../project.zig");
const Project = project_api.Project;
const LoadFrame = project_api.LoadFrame;
const Unit = project_api.Unit;
const Inputs = @import("../../module_input.zig");
const indexed = @import("../../parse_cache.zig").indexed_enabled;
const publication = @import("../publication/host.zig");
const exports = @import("../../public_exports.zig");
const restore = @import("../../semantic_cache/restore.zig");
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
    plan: publication.Plan = undefined,
    exports: if (generated) @import("body_exports/host.zig") else void = undefined,
    fn borrow(handle: *const anyopaque) *Body {
        return @ptrCast(@alignCast(@constCast(handle)));
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

        const request: std.meta.Child(entry.Input) = .{
            .body = @ptrCast(&body),
            .cached = project.semantic_cache != null,
            .exports = &body.exports.input,
        };

        const duplicate = zx.columns.invoke(entry.executeValue, project.allocator, &request) catch |err| return errorSet(err);

        if (duplicate) |name| return exports.reportDuplicate(project.allocator, project.reporter, name);

        return;
    }

    return seed(&body, input);
}

fn seed(body: *Body, input: anytype) zx.Error!void {
    var restored = false;

    if (body.project.semantic_cache != null) {
        restored = try restoreProjectBody(body);

        recordProjectCacheUse(body, restored);
    }

    if (!restored) try analyze(body, input);
    if (try installProjectFunction(body)) |count| try checkProjectOwnership(body, count);
    try publishSeedExports(body);
    if (projectBodyCacheable(body)) try registerProjectArtifact(body);
    try commitModule(body);
}

pub fn restoreProjectBody(handle: *const anyopaque) zx.Error!bool {
    const self = Body.borrow(handle);
    const project = self.project;
    const frame = self.frame;
    const cache = project.semantic_cache.?;
    const path = self.unit.path;
    const digest = try project.cache_context.get(project.allocator, self.entry, project.options.context);
    const cached = @TypeOf(cache.*).entry_store.find(&cache.entries, path, &frame.parsed.digest, digest) orelse return false;

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

        return true;
    }

    return false;
}

pub fn recordProjectCacheUse(handle: *const anyopaque, restored: bool) void {
    const cache = Body.borrow(handle).project.semantic_cache.?;

    if (restored) {
        cache.reused += 1;
    } else {
        cache.analyzed += 1;
    }
}

pub fn analyzeProjectBody(handle: *const anyopaque) zx.Error!void {
    const body = Body.borrow(handle);

    return switch (body.frame.parsed.result.*) {
        .native => |result| analyze(body, Inputs.Native{ .value = result.value.parsed }),
        .indexed => |*result| if (indexed) analyze(body, Inputs.Indexed{ .value = result }) else unreachable,
    };
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

pub fn installProjectFunction(handle: *const anyopaque) zx.Error!?u64 {
    const body = Body.borrow(handle);
    const project = body.project;

    const plan = try publication.module(&body.program, .{
        .entry = body.entry,
        .declared = body.declared,
        .linked = project.functions.count(),
        .restored = if (body.restored) |*value| value else null,
        .check_ownership = body.check_ownership,
        .cache = project.semantic_cache != null,
    });

    body.plan = plan;
    body.unit.function = plan.id;

    if (plan.append) try project.functions.append(project.allocator, @import("../../function_body.zig").value(body.program));
    if (comptime generated) body.exports.bind(&body.program, body.frame, plan.id);

    return if (plan.ownership_count) |count| count else null;
}

pub fn checkProjectOwnership(handle: *const anyopaque, count: u64) zx.Error!void {
    const body = Body.borrow(handle);
    const project = body.project;
    const program = &body.program;
    program.functions = project.functions.view().prefix(@intCast(count));
    program.output_ownership = try @import("../../../ownership/check.zig").analyze(project.allocator, program.*, project.reporter);

    if (body.unit.function) |id| project.functions.ownership.items[@backingInt(id)] = switch (program.output_ownership) {
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

pub fn projectBodyCacheable(handle: *const anyopaque) bool {
    return Body.borrow(handle).plan.publish_artifact;
}

pub fn registerProjectArtifact(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const body = Body.borrow(handle);
    const project = body.project;
    const index = project.modules.items.len;

    try project.cache_records.append(project.arena.child_allocator, index);

    if (body.entry) project.cache_root = index;
}

pub fn commitProjectModule(handle: *const anyopaque, types: []const u8, constants: []const u8, members: []const u8, entry: ?u32) std.mem.Allocator.Error!void {
    const body = Body.borrow(handle);
    const rows = @import("../exports/publication/rows.zig");
    const unit = body.unit;

    unit.exports = rows.typedRows(ir.Export, types);
    unit.constants = rows.typedRows(ir.Constant, constants);
    unit.members = rows.typedRows(project_api.FunctionImport, members);
    unit.function = if (entry) |id| @fromBackingInt(id) else null;

    try commitModule(body);
}

fn commitModule(body: *Body) std.mem.Allocator.Error!void {
    const project = body.project;
    const frame = body.frame;
    const program = &body.program;

    try project.modules.append(project.allocator, .{
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
        .body = body.plan.body,
        .own_function = body.plan.own_function,
    });

    if (body.entry) {
        program.types = .{};
        program.functions = .{};
        project.entry_program = program.*;
    }
}
