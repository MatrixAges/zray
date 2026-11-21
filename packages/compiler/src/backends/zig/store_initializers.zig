const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const modules = @import("modules.zig");
const names = @import("genz").zx.names;
const generated = @import("parser_options").generated_parser;
const native = if (generated) @import("output_execution_abi").layouts.@"zig:output_host" else struct {};
const workflow = if (generated) @import("generated_application_initializer_workflow") else struct {};
const Plan = if (generated) std.meta.Child(@FieldType(std.meta.Child(workflow.Input), "plan")) else void;
const Candidate = if (generated) native.InitializerCandidate else void;
const Origin = if (generated) native.InitializerOrigin else void;
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

    const input: std.meta.Child(workflow.Input) = .{
        .target = @ptrCast(&frame),
        .plan = &frame.plan,
        .paths = application.stores.paths,
        .types = application.stores.types,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const status = workflow.executeIn(fixed.allocator(), &input) catch |err| return failure(err);

    switch (status) {
        .DuplicateInitializer => return error.DuplicateInitializer,
        .MissingInitializer => return error.MissingInitializer,
        .InvalidInitializer => return error.InvalidInitializer,
        .Ready => {},
    }

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
    buckets: []u64 = &.{},
    values: []u32 = &.{},
    plan: Plan = undefined,
    candidate: Candidate = undefined,
    linked_source: Initializer = undefined,
    current: Initializer.Borrowed = undefined,
    fn fromHandle(handle: *const anyopaque) *@This() {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
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

        if (count > 1) self.buckets = try frontend.project.source_index.Map.bucketsFor(self.scratch, count);

        self.values = try self.scratch.alloc(u32, count);

        self.plan = .{
            .count = count,
            .owned = options.initializers.len,
            .source_end = selection.source_end,
            .linked = selection.indices,
            .expected = expected,
            .keys = @ptrCast(&self.keys),
            .buckets = @ptrCast(&self.buckets),
            .capacity = self.buckets.len,
            .values = @ptrCast(&self.values),
        };
    }
};

pub fn readApplicationInitializer(handle: *const anyopaque, origin: Origin, index: u64) names.Error!?*const Candidate {
    const frame = Application.fromHandle(handle);
    const options = frame.options;
    const position: usize = @intCast(index);

    const initial = switch (origin) {
        .Owned => options.initializers[position].borrow(),
        .Borrowed => options.borrowed_initializers[position],
        .Linked => row: {
            frame.linked_source = linked(frame.application, options.analysis.store_initializers[position]);

            break :row frame.linked_source.borrow();
        },
    };

    const validation = @import("store_initializers/validation.zig");

    if (!try validation.validate(frame.name_workspace.child_allocator, initial.program, .allowed)) return null;

    const actual = try names.typeNamesIn(frame.name_workspace.allocator(), initial.program, options.analysis.nominal_types);

    frame.current = initial;
    frame.candidate = .{ .identity = initial.identity, .type_id = @backingInt(initial.program.output_type), .names = actual };

    return &frame.candidate;
}

pub fn emitApplicationInitializer(handle: *const anyopaque, row: u64) modules.Error!void {
    const frame = Application.fromHandle(handle);
    const current = frame.current;
    const index: usize = @intCast(row);
    const types = frame.plan.expected;
    _ = frame.name_workspace.reset(.retain_capacity);
    const published = try @import("publication/initializer.zig").emit(frame.owned, frame.name_workspace.child_allocator, current.identity, current.schema_version, current.program, .{ .types = types, .functions = &.{} }, frame.options.cache);
    frame.files[frame.existing.len + index] = published.file;
    frame.entries[index] = published.entry;
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
