const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const modules = @import("modules.zig");
const names = @import("names.zig");
const Cache = @import("cache.zig");
const InitializerView = @import("store_initializers/view.zig");
const Publication = @import("state/publication.zig");
pub const Options = struct { analysis: *const frontend.AnalysisResult, cache: ?*Cache = null };
pub const Error = names.Error || error{ InvalidAnalysis, MissingInitializer, InvalidInitializer, DuplicateState };

pub fn append(bundle: *modules.Bundle, options: Options) Error!void {
    if (comptime !@import("parser_options").generated_parser) return @import("state_seed.zig").append(bundle, .{ .analysis = options.analysis, .cache = options.cache });

    var scratch = std.heap.ArenaAllocator.init(bundle.arena.child_allocator);

    defer scratch.deinit();

    const temporary = scratch.allocator();

    if (!try available(temporary, bundle, options.analysis)) return;

    const program = options.analysis.value.ir;
    const allocator = bundle.arena.allocator();
    const shared = try names.create(allocator, bundle.arena.child_allocator, program, options.analysis.nominal_types);
    const independent = try frontend.storesOwnValues(bundle.arena.child_allocator, program);
    const entry = @import("generated_state_bindings");
    const Input = std.meta.Child(entry.Input);
    const Stores = std.meta.Child(@FieldType(Input, "stores"));
    const Initializers = std.meta.Child(@FieldType(Input, "initializers"));
    const stores = zx.columns.borrow(Stores, &program.stores);
    const initializers = try InitializerView.init(temporary, bundle.store_initializers);

    const input: Input = .{
        .stores = &stores,
        .type_names = shared.types,
        .initializers = &initializers.input(Initializers),
        .has_requirements = bundle.requirements != null,
    };

    const plan = zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| return failure(err);

    switch (plan.status) {
        .Ready => {},
        .MissingInitializer => return error.MissingInitializer,
        .InvalidInitializer => return error.InvalidInitializer,
        .InvalidAnalysis => return error.InvalidAnalysis,
        else => unreachable,
    }

    var publication = Publication{
        .bundle = bundle,
        .temporary = temporary,
        .imports = plan.imports,
        .writable = program.stores.writable,
        .independent = independent,
        .requirements = bundle.requirements.?,
        .cache = options.cache,
    };

    try publication.run();
}

fn available(allocator: std.mem.Allocator, bundle: *const modules.Bundle, analysis: *const frontend.AnalysisResult) Error!bool {
    const entry = @import("generated_state_available");
    const valid_ir = analysis.value == .ir;
    const count = if (valid_ir) analysis.value.ir.stores.count() else 0;
    const Parameter = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;

    const input: Input = .{
        .valid_ir = valid_ir,
        .store_count = count,
        .modules = zx.columns.slice(@FieldType(Input, "modules"), bundle.modules),
    };

    const status = entry.executeValue(allocator, if (comptime @typeInfo(Parameter) == .pointer) &input else input) catch |err| return failure(err);

    return switch (status) {
        .Ready => true,
        .NoChange => false,
        .InvalidAnalysis => error.InvalidAnalysis,
        .DuplicateState => error.DuplicateState,
        else => unreachable,
    };
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
