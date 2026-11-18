const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const Module = @import("module.zig");
const expression = @import("expression.zig");
const target = @import("call/target.zig");
const Lowering = @import("program.zig");
pub const Metadata = @import("project/mixed/metadata.zig");

pub const Body = struct {
    lowered: Lowering.Result,
    nominal_types: @FieldType(frontend.AnalysisResult, "nominal_types"),
    metadata: ?*Metadata,
};

pub const Value = union(enum) { body: Body, diagnostic: target.Diagnostic };

pub const Options = struct {
    entry: bool,
    aliases: frontend.expressions.BindingColumns = .{},
    module: rx.ModuleSource,
    calls: @import("project/prepare.zig").Calls.Slice,
    ids: []const zx.ir.FunctionId,
    arguments: @import("project/call_inputs.zig").Module,
    plan: @import("project/flow.zig").Plan,
    bindings: Module.Bindings,
    tasks: []const zx.ir.TypeId = &.{},
    types: zx.ir.TypeTable,
    nominal_types: @FieldType(frontend.AnalysisResult, "nominal_types"),
    native_modules: zx.ir.NativeModuleTable = .{},
    shared_functions: zx.ir.FunctionTable,
    verified_functions: zx.ir.FunctionTable = .{},
    store_initializers: []const frontend.project.compiled.StoreInitializer = &.{},
    input_type: zx.ir.TypeId,
    output_type: zx.ir.TypeId,
};

pub fn compile(allocator: std.mem.Allocator, scratch: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Value {
    var scope = std.heap.ArenaAllocator.init(scratch);

    defer scope.deinit();

    var flow = @import("flow_compile.zig"){
        .allocator = allocator,
        .scratch = scratch,
        .binding_allocator = scope.allocator(),
        .retain_metadata = options.entry,
        .owner = options.module.path,
        .aliases = options.aliases,
        .types = options.types,
        .native_modules = options.native_modules,
        .shared_functions = options.shared_functions,
        .verified_functions = options.verified_functions,
        .output_type = options.output_type,
        .inputs = &options,
        .results = options.bindings,
        .tasks = options.tasks,
        .plan = &options.plan,
        .unit_input = options.input_type == @as(zx.ir.TypeId, @fromBackingInt(@intCast(@backingInt(zx.ir.Scalar.void)))),
    };

    if (options.input_type != @as(zx.ir.TypeId, @fromBackingInt(@intCast(@backingInt(zx.ir.Scalar.void))))) try flow.bindings.append(flow.binding_allocator, .{ .name = "$in", .type_id = options.input_type });

    _ = flow.root(options.plan.root) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return diagnostic(allocator, options.module.path, flow.issue.?);
    };

    const types = flow.types;
    const calls = flow.calls;
    const native_modules = options.native_modules;

    for (calls.items) |*call| {
        call.callee.types = types;
        call.argument.types = types;
        call.argument.native_modules = native_modules;

        if (frontend.checks_internal_ir) if (try frontend.validateIrExtending(allocator, call.callee, options.verified_functions)) |issue| return invalid(allocator, options, issue);
    }

    var lowered = Lowering.lower(allocator, .{
        .owner = options.module.path,
        .types = types,
        .input_type = options.input_type,
        .output_type = options.output_type,
        .calls = calls.items,
        .native_modules = native_modules,
        .shared_functions = options.shared_functions,
        .store_initializers = options.store_initializers,
        .flow = &flow.compiled,
        .retain_metadata = flow.retain_metadata,
        .split_functions = @import("rx_options").generated_graph and !frontend.checks_internal_ir,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.UnreachableFlow or err == error.IncompleteFlow) return invalid(allocator, options, .{ .code = .return_path, .span = .{ .start = 0, .end = 0 }, .message = if (err == error.UnreachableFlow) "steps after a terminating Return or Switch are unreachable" else "every RX path must return Output" });

        return invalid(allocator, options, .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = "RX expression environment cannot be linked to the module program" });
    };

    const program = &lowered.program;
    var reporter: zx.Reporter = .{};

    program.output_ownership = frontend.analyzeOwnershipWithSuffix(allocator, program.*, lowered.function_suffix, &reporter) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return invalid(allocator, options, reporter.diagnostic.?);
    };

    if (frontend.checks_internal_ir) if (try frontend.validateIrExtending(allocator, program.*, options.verified_functions)) |issue| return invalid(allocator, options, issue);

    return .{ .body = .{
        .lowered = lowered,
        .nominal_types = options.nominal_types,
        .metadata = if (options.entry) try Metadata.capture(&flow) else null,
    } };
}

fn diagnostic(allocator: std.mem.Allocator, owner: []const u8, issue: expression.Diagnostic) std.mem.Allocator.Error!Value {
    const failed = try target.failure(allocator, .{ .path = owner, .location = issue.location, .code = @tagName(issue.issue.code), .message = issue.issue.message });

    return .{ .diagnostic = failed.diagnostic };
}

fn invalid(allocator: std.mem.Allocator, options: Options, issue: zx.Diagnostic) std.mem.Allocator.Error!Value {
    const location = @import("source_map.zig").locateSource(options.module, issue.span.start);
    const failed = try target.failure(allocator, .{ .path = options.module.path, .location = location, .code = @tagName(issue.code), .message = issue.message });

    return .{ .diagnostic = failed.diagnostic };
}
