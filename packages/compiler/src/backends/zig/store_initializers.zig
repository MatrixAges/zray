const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const modules = @import("modules.zig");
const names = @import("genz").zx.names;
const generated = @import("parser_options").generated_parser;
const workflow = if (generated) @import("generated_application_initializer_workflow") else struct {};
const Input = if (generated) std.meta.Child(workflow.Input) else void;
const Plan = if (generated) std.meta.Child(@FieldType(Input, "plan")) else void;
const Candidate = if (generated) std.meta.Child(@typeInfo(@FieldType(Input, "candidate")).optional.child) else void;
pub const Initializer = frontend.project.SourceStoreInitializer;

pub const Options = struct {
    analysis: *const frontend.AnalysisResult,
    initializers: []const Initializer = &.{},
    borrowed_initializers: []const Initializer.Borrowed = &.{},
    cache: ?*@import("cache.zig") = null,
};

pub const Error = modules.Error || error{ InvalidInitializer, DuplicateInitializer, MissingInitializer };

pub fn append(bundle: *modules.Bundle, options: Options) Error!void {
    if (comptime !generated) return @import("store_initializers_seed.zig").append(bundle, options);
    if (options.analysis.value != .ir or bundle.store_initializers.len != 0) return error.InvalidInitializer;

    const application = &options.analysis.value.ir;
    var scratch = std.heap.ArenaAllocator.init(bundle.arena.child_allocator);
    var buffer: [4096]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    var frame: Application = .{
        .options = options,
        .application = application,
        .owned = bundle.arena.allocator(),
        .scratch = scratch.allocator(),
        .name_workspace = .init(bundle.arena.child_allocator),
        .existing = bundle.modules,
    };

    defer frame.name_workspace.deinit();

    try frame.prepare();

    const allocator = buffered.allocator();

    var input: Input = .{
        .plan = &frame.plan,
        .paths = application.stores.paths,
        .types = application.stores.types,
        .phase = .Prepare,
        .row = 0,
        .candidate = null,
        .values = &.{},
        .buckets = &.{},
    };

    const prepared = try run(allocator, &input);
    const buckets = try allocator.alloc(u64, @intCast(prepared.capacity));
    const values = try allocator.alloc(u32, frame.entries.len);

    @memset(buckets, 0);

    input.buckets = buckets;
    input.values = values;

    for (values, 0..) |*value, row| {
        input.phase = .Select;
        input.row = row;

        const selected = try run(allocator, &input);
        const request = selected.request.?;
        var linked_source: Initializer = undefined;
        const current = frame.source(request, &linked_source);
        const candidate = try frame.describe(current);
        input.phase = .Admit;
        input.candidate = if (candidate) |*item| item else null;

        const admitted = try run(allocator, &input);

        try check(admitted.status);

        input.candidate = null;

        try frame.emit(row, current);

        value.* = candidate.?.type_id;

        if (admitted.slot) |slot| buckets[slot] = row + 1;
    }

    input.phase = .Coverage;

    try check((try run(allocator, &input)).status);

    bundle.modules = frame.files;
    bundle.store_initializers = frame.entries;
}

const Application = struct {
    options: Options,
    application: *const zx.ir.Program,
    owned: std.mem.Allocator,
    scratch: std.mem.Allocator,
    name_workspace: std.heap.ArenaAllocator,
    existing: []const modules.File,
    files: []modules.File = undefined,
    entries: []modules.StoreInitializer = undefined,
    keys: zx.memory.TextColumn = undefined,
    plan: Plan = undefined,
    fn prepare(self: *@This()) (names.Error || error{InvalidInitializer})!void {
        const options = self.options;
        const backing = self.name_workspace.child_allocator;
        const expected = try names.createTypes(self.owned, backing, self.application, options.analysis.nominal_types);
        const selection = try @import("store_initializers/selection.zig").plan(self.scratch, self.application, options.analysis.store_initializers, options.initializers.len, options.borrowed_initializers.len, self.existing.len);
        const count: usize = @intCast(selection.count);
        self.files = try self.owned.alloc(modules.File, @intCast(selection.file_count));
        self.entries = try self.owned.alloc(modules.StoreInitializer, count);

        // Only published rows can be read by a later lookup.
        self.keys = zx.memory.borrowTextColumn("identity", @as([]const modules.StoreInitializer, self.entries));

        @memcpy(self.files[0..self.existing.len], self.existing);

        self.plan = .{
            .count = count,
            .owned = options.initializers.len,
            .source_end = selection.source_end,
            .linked = selection.indices,
            .expected = expected,
            .keys = @ptrCast(&self.keys),
        };
    }
    fn source(self: *const Application, request: anytype, linked_source: *Initializer) Initializer.Borrowed {
        const index: usize = @intCast(request.index);

        return switch (request.origin) {
            .Owned => self.options.initializers[index].borrow(),
            .Borrowed => self.options.borrowed_initializers[index],
            .Linked => selected: {
                linked_source.* = linked(self.application, self.options.analysis.store_initializers[index]);

                break :selected linked_source.borrow();
            },
        };
    }

    fn describe(self: *Application, current: Initializer.Borrowed) names.Error!?Candidate {
        const validation = @import("store_initializers/validation.zig");

        if (!try validation.validate(self.name_workspace.child_allocator, current.program, .allowed)) return null;

        const actual = try names.typeNamesIn(self.name_workspace.allocator(), current.program, self.options.analysis.nominal_types);

        return .{ .identity = current.identity, .type_id = @backingInt(current.program.output_type), .names = actual };
    }
    fn emit(self: *Application, row: usize, current: Initializer.Borrowed) modules.Error!void {
        _ = self.name_workspace.reset(.retain_capacity);
        const published = try @import("publication/initializer.zig").emit(self.owned, self.name_workspace.child_allocator, current.identity, current.schema_version, current.program, .{ .types = self.plan.expected, .functions = &.{} }, self.options.cache);
        self.files[self.existing.len + row] = published.file;
        self.entries[row] = published.entry;
    }
};

fn run(allocator: std.mem.Allocator, input: *const Input) Error!std.meta.Child(workflow.Output) {
    const output = workflow.executeIn(allocator, input) catch |err| return failure(err);

    return output.*;
}

fn check(status: anytype) Error!void {
    return switch (status) {
        .DuplicateInitializer => error.DuplicateInitializer,
        .MissingInitializer => error.MissingInitializer,
        .InvalidInitializer => error.InvalidInitializer,
        .Ready => {},
    };
}

fn failure(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        error.InvalidInitializer => error.InvalidInitializer,
        error.InvalidAnalysis => error.InvalidAnalysis,
        error.ConflictingFunction => error.ConflictingFunction,
        error.InvalidNames => error.InvalidNames,
        error.InvalidFunction => error.InvalidFunction,
        error.MissingNominalOrigin => error.MissingNominalOrigin,
        error.InvalidNominalOrigin => error.InvalidNominalOrigin,
        else => unreachable,
    };
}

fn linked(application: *const zx.ir.Program, initial: frontend.project.compiled.StoreInitializer) Initializer {
    const function = application.functions.at(@backingInt(initial.function));

    return .{
        .identity = initial.identity,
        .schema_version = initial.schema_version,
        .program = .{
            .file_name = function.file_name,
            .types = application.types,
            .input_type = function.input_type,
            .output_type = function.output_type,
            .output_ownership = function.output_ownership,
            .symbols = function.symbols,
            .expressions = function.expressions,
            .body = function.body,
            .contracts = function.contracts,
            .stores = function.stores,
            .store_mode = function.store_mode,
        },
    };
}
