const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const Flow = @import("flow_compile.zig");
const Captures = @import("task_captures.zig");
const Layout = @import("task_captures/layout.zig");
const Capture = @import("program/capture.zig");
const Schedule = @import("flow_compile/schedule.zig");

pub fn compile(parent: *Flow, branch: *const @import("project/flow.zig").Task, outputs: *frontend.expressions.BindingStorage) Flow.Error!u32 {
    const node = branch.node.*;
    const allocator = parent.allocator;
    const environment = frontend.expressions.BindingColumns.view(parent.bindings.slice());
    var arena = std.heap.ArenaAllocator.init(parent.scratch);
    var buffer: [std.heap.page_size_min / 8]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const temporary = scratch.allocator();
    const children = environment.types;

    if (!Layout.admits(parent.types, children)) return failure(parent, node, .{ .code = .ownership, .span = .{ .start = 0, .end = 0 }, .message = "tasks cannot be placed in tuples" });

    var reporter: zx.Reporter = .{};

    var types = frontend.types{
        .allocator = allocator,
        .reporter = &reporter,
        .declarations = &.{},
        .items = try parent.takeTypeStorage(),
    };

    const id = branch.id.?;
    const output_type = parent.tasks[id];
    var captures = try Captures.init(temporary, children);

    var nested = Flow{
        .allocator = allocator,
        .scratch = parent.scratch,
        .binding_allocator = temporary,
        .owner = parent.owner,
        .aliases = parent.aliases,
        .types = types.items.view(),
        .type_storage = types.items,
        .native_modules = parent.native_modules,
        .shared_functions = parent.shared_functions,
        .verified_functions = parent.verified_functions,
        .output_type = output_type,
        .loaded = parent.loaded,
        .results = parent.results,
        .tasks = parent.tasks,
        .plan = parent.plan,
        .captures = &captures,
        .next_binding = parent.next_binding,
        .unit_input = parent.unit_input,
        .bindings = try Layout.scope(temporary, types.items.view(), environment, parent.nonnull.items),
    };

    types.items = .{};

    const span: zx.Span = .{ .start = node.location.offset, .end = node.location.offset };

    const effect_issue: zx.Diagnostic = .{
        .code = .unsupported,
        .span = span,
        .message = "Parallel Task requires pure computation without Store access or native external calls",
    };

    var selected: Capture.Parameters = undefined;
    var layout: Layout = undefined;
    var input_type: zx.ir.TypeId = undefined;
    var environment_type: zx.ir.TypeId = undefined;
    var program: zx.ir.Program = undefined;
    var argument: zx.ir.Program = undefined;
    var call_id: u32 = undefined;

    inline for (comptime Schedule.steps(.ParallelTask)) |action| {
        switch (action) {
            .Done => {},
            .CompileParallelTaskBody => {
                _ = nested.root(branch.body) catch |err| {
                    parent.issue = nested.issue;

                    return err;
                };

                parent.next_binding = nested.next_binding;
            },
            .CheckTaskCalls => for (nested.calls.items) |*call| {
                if (call.getters.len != 0 or !try frontend.isParallelSafe(allocator, call.callee)) return failure(parent, node, effect_issue);

                call.callee.types = nested.types;
                call.argument.types = nested.types;
            },
            .ResolveCaptures => {
                const positions = try captures.positions(temporary, children);

                types.items = try nested.takeTypeStorage();
                layout = try Layout.plan(temporary, children, positions, nested.bindings.items(.type_id));
                selected = .{ .names = environment.names, .positions = positions, .types = layout.parameter_types };

                input_type = types.tuple(selected.types) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;

                    return failure(parent, node, reporter.diagnostic.?);
                };

                environment_type = if (layout.optional_count != 0) types.tuple(layout.source_types) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;

                    return failure(parent, node, reporter.diagnostic.?);
                } else input_type;

                parent.type_storage = types.items;
                parent.types = parent.type_storage.view();
            },
            .LowerParallelTask => {
                const owner = try std.fmt.allocPrint(allocator, "{s}#parallel-task-{d}", .{ parent.owner, id });

                const lowered = @import("program.zig").lower(allocator, .{
                    .owner = owner,
                    .types = parent.types,
                    .input_type = input_type,
                    .output_type = output_type,
                    .captures = selected,
                    .calls = nested.calls.items,
                    .native_modules = parent.native_modules,
                    .shared_functions = parent.shared_functions,
                    .flow = &nested.compiled,
                }) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;

                    return failure(parent, node, .{
                        .code = if (err == error.IncompleteFlow or err == error.UnreachableFlow) .return_path else .contract,
                        .span = span,
                        .message = if (err == error.IncompleteFlow) "every Parallel Task path must return its output" else "Parallel Task expressions cannot be linked",
                    });
                };

                program = lowered.program;
            },
            .CheckTaskProgram => if (!try frontend.isParallelSafe(allocator, program)) return failure(parent, node, effect_issue),
            .AnalyzeTaskOwnership => program.output_ownership = frontend.analyzeOwnership(allocator, program, &reporter) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;

                return failure(parent, node, reporter.diagnostic.?);
            },
            .ValidateTaskProgram => if (frontend.checks_internal_ir) {
                if (try frontend.validateIrExtending(allocator, program, parent.verified_functions)) |issue| return failure(parent, node, issue);
            },
            .BuildCaptureArgument => {
                argument = try Capture.argument(parent.metadataAllocator(), parent.owner, parent.types, environment_type, input_type, selected, layout, span);

                if (parent.captures) |outer| outer.observeMapped(argument.expressions.references, selected.positions);
            },
            .PublishParallelTask => {
                const out = try parent.publishResult(outputs);
                call_id = try parent.appendCall(.{ .callee = program, .argument = argument, .out = out });
            },
            else => unreachable,
        }
    }

    return call_id;
}

fn failure(parent: *Flow, node: rx.ast.Node, issue: zx.Diagnostic) Flow.Error {
    parent.issue = .{ .location = node.location, .issue = issue };

    return error.InvalidFlow;
}
