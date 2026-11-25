const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const Flow = @import("flow_compile.zig");
const Branch = @import("project/flow.zig").Task;
const Captures = @import("task_captures.zig");
const Layout = @import("task_captures/layout.zig");
const Capture = @import("program/capture.zig");
const generated = @import("rx_options").generated_graph;

const Work = struct {
    parent: *Flow,
    branch: *const Branch,
    outputs: *frontend.expressions.BindingStorage,
    temporary: std.mem.Allocator,
    environment: frontend.expressions.BindingColumns,
    reporter: zx.Reporter = .{},
    types: frontend.types = undefined,
    captures: Captures = undefined,
    nested: Flow = undefined,
    selected: Capture.Parameters = undefined,
    layout: Layout = undefined,
    input_type: zx.ir.TypeId = undefined,
    environment_type: zx.ir.TypeId = undefined,
    program: zx.ir.Program = undefined,
    suffix: ?*const zx.ir.FunctionTable = null,
    argument: zx.ir.Program = undefined,
    fn bind(self: *Work) Flow.Error!void {
        const parent = self.parent;
        const temporary = self.temporary;
        const children = self.environment.types;

        if (!Layout.admits(parent.types, children)) return self.fail(.{
            .code = .ownership,
            .span = .{ .start = 0, .end = 0 },
            .message = "tasks cannot be placed in tuples",
        });

        self.types = .{
            .allocator = parent.allocator,
            .reporter = &self.reporter,
            .declarations = &.{},
            .items = try parent.takeTypeStorage(),
        };

        const output_type = parent.tasks[self.branch.id.?];

        self.captures = try Captures.init(temporary, children);

        self.nested = .{
            .allocator = parent.allocator,
            .scratch = parent.scratch,
            .binding_allocator = temporary,
            .owner = parent.owner,
            .aliases = parent.aliases,
            .types = self.types.items.view(),
            .type_storage = self.types.items,
            .native_modules = parent.native_modules,
            .shared_functions = parent.shared_functions,
            .verified_functions = parent.verified_functions,
            .output_type = output_type,
            .inputs = parent.inputs,
            .results = parent.results,
            .tasks = parent.tasks,
            .plan = parent.plan,
            .captures = &self.captures,
            .next_binding = parent.next_binding,
            .unit_input = parent.unit_input,
            .bindings = try Layout.scope(temporary, self.types.items.view(), self.environment, parent.nonnull.items),
        };

        self.types.items = .{};
    }
    fn span(self: *const Work) zx.Span {
        const offset = self.branch.node.location.offset;

        return .{ .start = offset, .end = offset };
    }
    fn fail(self: *Work, issue: zx.Diagnostic) Flow.Error {
        self.parent.issue = .{ .location = self.branch.node.location, .issue = issue };

        return error.InvalidFlow;
    }
    fn rejectEffects(self: *Work) Flow.Error {
        return self.fail(.{
            .code = .unsupported,
            .span = self.span(),
            .message = "Parallel Task requires pure computation without Store access or native external calls",
        });
    }
    fn diagnostic(self: *Work, err: anyerror) Flow.Error {
        return if (err == error.OutOfMemory) error.OutOfMemory else self.fail(self.reporter.diagnostic.?);
    }
    fn publish(self: *Work, result: Flow.Result) Flow.Error!u32 {
        try result.publish(self.parent.binding_allocator, self.outputs);

        return self.parent.appendCall(.{
            .callee = self.program,
            .callee_suffix = self.suffix,
            .argument = self.argument,
            .out = result.name,
        });
    }
    fn borrow(handle: *anyopaque) *Work {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn compile(parent: *Flow, branch: *const Branch, outputs: *frontend.expressions.BindingStorage) Flow.Error!u32 {
    var arena = std.heap.ArenaAllocator.init(parent.scratch);
    var buffer: [std.heap.page_size_min / 8]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    var work: Work = .{
        .parent = parent,
        .branch = branch,
        .outputs = outputs,
        .temporary = scratch.allocator(),
        .environment = frontend.expressions.BindingColumns.view(parent.bindings.slice()),
    };

    try work.bind();

    if (comptime generated) {
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const entry = @import("generated_rx_compile_parallel_task");
        const Input = std.meta.Child(entry.Input);
        const result_slots: zx.memory.ColumnLengths = &.{&parent.next_binding};

        const input: Input = .{
            .frame = @ptrCast(&work),
            .results = &.{ .cursor = @ptrCast(&result_slots), .types = @ptrCast(parent.results.types) },
        };

        return entry.executeValue(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidFlow => error.InvalidFlow,
            else => unreachable,
        };
    }

    const handle: *anyopaque = &work;

    try compileParallelTaskBody(handle);
    try checkParallelTaskCalls(handle);
    try resolveParallelTaskCaptures(handle);
    try lowerParallelTaskProgram(handle);
    try checkParallelTaskProgram(handle);
    try analyzeParallelTaskOwnership(handle);
    try validateParallelTaskProgram(handle);
    try buildParallelTaskArgument(handle);

    return work.publish(parent.seedResult());
}

pub fn compileParallelTaskBody(handle: *anyopaque) Flow.Error!void {
    const work = Work.borrow(handle);

    _ = work.nested.root(work.branch.body) catch |err| {
        work.parent.issue = work.nested.issue;

        return err;
    };

    work.parent.next_binding = work.nested.next_binding;
}

pub fn checkParallelTaskCalls(handle: *anyopaque) Flow.Error!void {
    const work = Work.borrow(handle);

    for (work.nested.calls.items) |*call| {
        if (call.getters.len != 0 or !try frontend.isParallelSafeWithSuffix(work.parent.allocator, call.callee, call.callee_suffix)) return work.rejectEffects();

        call.callee.types = work.nested.types;
        call.argument.types = work.nested.types;
    }
}

pub fn resolveParallelTaskCaptures(handle: *anyopaque) Flow.Error!void {
    const work = Work.borrow(handle);

    work.types.items = try work.nested.takeTypeStorage();
    work.layout = try Layout.plan(work.temporary, work.environment.types, work.captures, work.nested.bindings.items(.type_id));
    work.selected = .{ .names = work.environment.names, .positions = work.layout.positions, .types = work.layout.parameter_types };
    work.input_type = work.types.tuple(work.selected.types) catch |err| return work.diagnostic(err);

    work.environment_type = if (work.layout.optional_count != 0)
        work.types.tuple(work.layout.source_types) catch |err| return work.diagnostic(err)

    else
        work.input_type;

    work.parent.type_storage = work.types.items;
    work.parent.types = work.parent.type_storage.view();
}

pub fn lowerParallelTaskProgram(handle: *anyopaque) Flow.Error!void {
    const work = Work.borrow(handle);
    const parent = work.parent;
    const allocator = parent.allocator;
    const owner = try std.fmt.allocPrint(allocator, "{s}#parallel-task-{d}", .{ parent.owner, work.branch.id.? });

    const lowered = @import("program.zig").lower(allocator, .{
        .owner = owner,
        .types = parent.types,
        .input_type = work.input_type,
        .output_type = work.nested.output_type,
        .captures = work.selected,
        .calls = work.nested.calls.items,
        .native_modules = parent.native_modules,
        .shared_functions = parent.shared_functions,
        .flow = &work.nested.compiled,
        .split_functions = generated and !frontend.checks_internal_ir,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return work.fail(.{
            .code = if (err == error.IncompleteFlow or err == error.UnreachableFlow) .return_path else .contract,
            .span = work.span(),
            .message = if (err == error.IncompleteFlow) "every Parallel Task path must return its output" else "Parallel Task expressions cannot be linked",
        });
    };

    work.program = lowered.program;

    if (lowered.function_suffix.count() != 0) {
        const tail = try allocator.create(zx.ir.FunctionTable);

        tail.* = lowered.function_suffix;
        work.suffix = tail;
    }
}

pub fn checkParallelTaskProgram(handle: *anyopaque) Flow.Error!void {
    const work = Work.borrow(handle);

    if (!try frontend.isParallelSafeWithSuffix(work.parent.allocator, work.program, work.suffix)) return work.rejectEffects();
}

pub fn analyzeParallelTaskOwnership(handle: *anyopaque) Flow.Error!void {
    const work = Work.borrow(handle);
    const suffix: zx.ir.FunctionTable = if (work.suffix) |tail| tail.* else .{};
    work.program.output_ownership = frontend.analyzeOwnershipWithSuffix(work.parent.allocator, work.program, suffix, &work.reporter) catch |err| return work.diagnostic(err);
}

pub fn validateParallelTaskProgram(handle: *anyopaque) Flow.Error!void {
    if (comptime !frontend.checks_internal_ir) return;

    const work = Work.borrow(handle);

    if (try frontend.validateIrExtending(work.parent.allocator, work.program, work.parent.verified_functions)) |issue| return work.fail(issue);
}

pub fn buildParallelTaskArgument(handle: *anyopaque) Flow.Error!void {
    const work = Work.borrow(handle);
    const parent = work.parent;

    work.argument = try Capture.argument(parent.metadataAllocator(), parent.owner, parent.types, work.environment_type, work.input_type, work.program.symbols.names, work.layout, work.span());

    if (parent.captures) |outer| outer.observeMapped(work.argument.expressions.references, work.selected.positions);
}

pub fn publishParallelTask(handle: *anyopaque, row: u64, visible: bool) Flow.Error!u32 {
    const work = Work.borrow(handle);

    return work.publish(work.parent.selectedResult(row, visible));
}
