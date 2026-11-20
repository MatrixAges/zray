const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const render = @import("../render.zig").render;
pub const Analysis = @import("function_analysis.zig");
pub const Names = struct { types: []const []const u8, functions: []const []const u8 };
/// `function` is one function's file; a value function's file holds only its value variant. `regular` is the same file
/// with the pointer-ABI `call` as well, for value functions some caller reaches through it.
pub const Unit = union(enum) { entry, function: ir.FunctionId, types, regular: ir.FunctionId };

pub const FunctionUnit = struct {
    id: ir.FunctionId,
    regular: bool,
    pub fn unit(self: FunctionUnit) Unit {
        return if (self.regular) .{ .regular = self.id } else .{ .function = self.id };
    }
};

pub const abi_view = @import("abi_view.zig");
pub const typeNames = @import("types/export_names.zig").build;
pub const Error = std.mem.Allocator.Error || error{ InvalidNames, InvalidFunction };
pub const PublicMember = struct { name: []const u8, function: ir.FunctionId };
pub const TypeScratch = @import("types/scratch.zig");

/// Function types for separately compiled files. Bodies are deliberately absent: importing a type
/// must not pull the owning function and its dependency graph into another compilation unit.
pub fn signatures(allocator: std.mem.Allocator, backing: std.mem.Allocator, program: ir.Program, names: Names, facts: Analysis, units: []const Unit) Error![]u8 {
    return signatureFiles(allocator, backing, program, names, facts, units);
}

pub fn functionSignatures(allocator: std.mem.Allocator, backing: std.mem.Allocator, program: ir.Program, names: Names, facts: Analysis, units: []const FunctionUnit) Error![]u8 {
    return signatureFiles(allocator, backing, program, names, facts, units);
}

fn signatureFiles(allocator: std.mem.Allocator, backing: std.mem.Allocator, program: ir.Program, names: Names, facts: Analysis, units: anytype) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    const temporary = arena.allocator();
    var lower = try initialize(temporary, backing, program, names, facts, null);
    var output: std.ArrayList(node.Declaration) = .empty;
    var emitted: std.StringHashMapUnmanaged(void) = .empty;

    try output.append(temporary, .{ .constant = .{ .name = "std", .value = try lower.builtin(.import, &.{try lower.builder.string("std")}) } });
    try @import("types.zig").lower(&lower, &output, false);

    for (units) |item| {
        const unit = if (@TypeOf(item) == FunctionUnit) item.unit() else item;

        const id = switch (unit) {
            .function, .regular => |id| id,
            else => continue,
        };

        const path = names.functions[@backingInt(id)];
        const name = std.fs.path.stem(path);

        if ((try emitted.getOrPut(temporary, name)).found_existing) continue;

        var selected = lower;
        const function_value = try selectFunction(&selected, id);

        if (comptime @import("genz_options").generated_analysis) {
            const signature_module = @import("modules/signature.zig");
            const variants = signature_module.select(function_value.external != null, selected.value_functions[@backingInt(id)], unit == .regular);
            const regular = if (variants.regular) try regularPrototype(&selected, id, function_value) else null;
            const value = if (variants.value) try selected.valuePrototype("signature") else null;

            try signature_module.append(&selected, &output, .{
                .name = name,
                .parameter_name = variants.parameter_name,
                .regular = regular,
                .value = value,
            });

            continue;
        }

        const value = function_value.external == null and selected.value_functions[@backingInt(id)];
        var variants: std.ArrayList(node.Declaration) = .empty;

        if (!value or unit == .regular) {
            const prototype = try regularPrototype(&selected, id, function_value);

            try variants.append(temporary, try signatureType(&selected, "call", prototype));
        }

        if (value) try variants.append(temporary, try signatureType(&selected, "callValue", try selected.valuePrototype("signature")));
        try output.append(temporary, .{ .constant = .{ .name = name, .exported = true, .value = try lower.builder.expression(.{ .namespace_type = variants.items }) } });
    }

    return render(allocator, lower.builder.nodes, output.items);
}

fn regularPrototype(lower: *Lower, id: ir.FunctionId, function_value: ir.Function) Error!node.Function {
    if (function_value.external != null) return @import("external.zig").prototype(lower, function_value, @backingInt(id));

    return lower.prototype("signature", false);
}

fn signatureType(lower: *Lower, name: []const u8, prototype: node.Function) Error!node.Declaration {
    var function_type = prototype;
    function_type.name = "signature";
    function_type.exported = false;
    function_type.inlined = false;
    function_type.body = try lower.builder.statements(&.{.unreachable_stmt});

    const parameters = try lower.allocator.dupe(node.Field, prototype.parameters);

    for (parameters) |*parameter| parameter.name = "_";

    function_type.parameters = parameters;

    const declarations = try lower.allocator.dupe(node.Declaration, &.{.{ .function = function_type }});
    const container = try lower.builder.expression(.{ .namespace_type = declarations });

    return .{ .constant = .{ .name = name, .exported = true, .value = try lower.builtin(.TypeOf, &.{try lower.builder.field(container, "signature")}) } };
}

fn selectFunction(lower: *Lower, id: ir.FunctionId) Error!ir.Function {
    if (@backingInt(id) >= lower.program.functions.count()) return error.InvalidFunction;

    const selected = lower.program.functions.at(@backingInt(id));

    try lower.selectFunction(id, selected);

    return selected;
}

pub fn publicEntry(allocator: std.mem.Allocator, backing: std.mem.Allocator, program: ir.Program, names: Names, facts: Analysis, members: []const PublicMember) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    const temporary = arena.allocator();
    var lower = try initialize(temporary, backing, program, names, facts, null);
    const prefix = try lower.declarations();
    const suffix = try @import("public_exports.zig").append(&lower, names, members);

    std.debug.assert(prefix.start + prefix.len == suffix.start);

    return @import("../render.zig").renderStored(allocator, lower.builder.nodes, .{ .start = prefix.start, .len = prefix.len + suffix.len });
}

pub fn entry(allocator: std.mem.Allocator, program: ir.Program, names: Names) Error![]u8 {
    return generate(allocator, program, names, .entry);
}

pub fn types(allocator: std.mem.Allocator, program: ir.Program, names: Names) Error![]u8 {
    return generate(allocator, program, names, .types);
}

pub fn function(allocator: std.mem.Allocator, program: ir.Program, id: ir.FunctionId, names: Names) Error![]u8 {
    return generate(allocator, program, names, .{ .function = id });
}

fn generate(allocator: std.mem.Allocator, program: ir.Program, names: Names, unit: Unit) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    return prepared(allocator, try @import("render.zig").prepare(arena.allocator(), program), names, unit);
}

pub fn prepared(allocator: std.mem.Allocator, program: ir.Program, names: Names, unit: Unit) Error![]u8 {
    if (unit == .function and @backingInt(unit.function) >= program.functions.count()) return error.InvalidFunction;
    if (names.types.len != program.types.count() or names.functions.len != program.functions.count()) return error.InvalidNames;

    var analysis = try Analysis.create(allocator, program);

    defer analysis.deinit();

    return analyzed(allocator, allocator, program, names, unit, analysis.value);
}

pub fn analyzed(allocator: std.mem.Allocator, backing: std.mem.Allocator, program: ir.Program, names: Names, unit: Unit, facts: Analysis) Error![]u8 {
    return analyzedWithScratch(allocator, backing, program, names, unit, facts, null);
}

pub fn analyzedWithScratch(allocator: std.mem.Allocator, backing: std.mem.Allocator, program: ir.Program, names: Names, unit: Unit, facts: Analysis, scratch: ?*TypeScratch) Error![]u8 {
    return switch (unit) {
        .entry => entryPrepared(allocator, backing, program, names, facts),
        .types => typesPrepared(allocator, backing, program, names, facts),
        .function => |id| functionPrepared(allocator, backing, program, id, names, facts, false, scratch),
        .regular => |id| functionPrepared(allocator, backing, program, id, names, facts, true, scratch),
    };
}

fn entryPrepared(allocator: std.mem.Allocator, backing: std.mem.Allocator, program: ir.Program, names: Names, facts: Analysis) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    var lower = try initialize(arena.allocator(), backing, program, names, facts, null);

    return @import("../render.zig").renderStored(allocator, lower.builder.nodes, try lower.declarations());
}

fn typesPrepared(allocator: std.mem.Allocator, backing: std.mem.Allocator, program: ir.Program, names: Names, facts: Analysis) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    var lower = try initialize(arena.allocator(), backing, program, names, facts, null);

    lower.shared_types = false;

    return @import("../render.zig").renderStoredScoped(allocator, backing, lower.builder.nodes, try @import("type_bundle.zig").declarations(&lower));
}

fn functionPrepared(allocator: std.mem.Allocator, backing: std.mem.Allocator, program: ir.Program, id: ir.FunctionId, names: Names, facts: Analysis, regular: bool, scratch: ?*TypeScratch) Error![]u8 {
    if (@backingInt(id) >= program.functions.count()) return error.InvalidFunction;

    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    const working = if (@import("genz_options").generated_analysis) scratch else null;

    defer if (working) |storage| storage.reset();

    const temporary = arena.allocator();
    var lower = try initialize(temporary, backing, program, names, facts, working);
    const selected = try selectFunction(&lower, id);

    lower.plan = lower.plans[@backingInt(id)];
    lower.names = try temporary.alloc([]const u8, selected.symbols.count());
    lower.may_grow = if (@backingInt(id) < lower.growth_functions.len) lower.growth_functions[@backingInt(id)] else true;
    lower.used = try temporary.alloc(bool, selected.symbols.count());
    lower.cache_reads = try temporary.alloc(u64, selected.expressions.count());

    const workflow = @import("module/workflow.zig");
    const form = workflow.functionForm(selected.external != null, lower.value_functions[@backingInt(id)], regular);

    const declarations = switch (form) {
        inline else => |variant| try functionDeclarations(&lower, selected, id, variant),
    };

    return @import("../render.zig").renderStored(allocator, lower.builder.nodes, declarations);
}

fn functionDeclarations(lower: *Lower, selected: ir.Function, id: ir.FunctionId, comptime form: @import("module/workflow.zig").FunctionForm) Error!@import("../node/stored.zig").Declarations {
    const temporary = lower.allocator;
    var output: std.ArrayList(node.Declaration) = .empty;
    var suffix: std.ArrayList(node.Declaration) = .empty;
    var comparisons: std.ArrayList(ir.TypeId) = .empty;
    var task_declarations = @import("auxiliary.zig").init();

    lower.comparisons = &comparisons;
    lower.task_declarations = &task_declarations;
    lower.local_regular_function = form != .Value;

    inline for (comptime @import("module/workflow.zig").functionSteps(form)) |step| switch (step) {
        .Standard => try output.append(temporary, .{ .constant = .{ .name = "std", .value = try lower.builtin(.import, &.{try lower.builder.string("std")}) } }),
        .Types => try @import("types.zig").lower(lower, &output, false),
        .Store => try @import("store.zig").declaration(lower, &output),
        .NativeImport => {
            const external = selected.external.?;
            const modules = lower.program.native_modules;
            const module = modules.at(@backingInt(external.module));
            const native_names = try temporary.alloc([]const u8, modules.count());

            @memset(native_names, "");
            native_names[@backingInt(external.module)] = "zx_native";

            lower.native_names = native_names;

            try output.append(temporary, .{ .constant = .{ .name = "zx_native", .value = try lower.builtin(.import, &.{try lower.builder.string(module.import_name)}) } });
        },
        .NativeBody, .RegularBody, .ValueBody => {
            var declaration = switch (step) {
                .NativeBody => try @import("external.zig").lower(lower, selected, @backingInt(id)),
                .RegularBody => if (try @import("functions/adapter.zig").build(lower, id)) |adapter| adapter else try lower.function("call", false),
                .ValueBody => try lower.functionValue("callValue"),
                else => unreachable,
            };

            if (step != .ValueBody) declaration.function.name = "call";

            declaration.function.exported = true;

            try output.append(temporary, declaration);
        },
        .ParallelAllocator => {
            if (lower.uses_parallel) try output.append(temporary, try @import("parallel/allocator.zig").declaration(lower));
        },
        .Comparisons => {
            for (comparisons.items) |type_id| try suffix.append(temporary, try @import("comparison.zig").ordering(lower, type_id));
        },
    };

    return task_declarations.assemble(temporary, lower.builder.nodes, output.items, suffix.items);
}

fn initialize(allocator: std.mem.Allocator, backing: std.mem.Allocator, program: ir.Program, names: Names, facts: Analysis, scratch: ?*TypeScratch) Error!Lower {
    if (names.types.len != program.types.count() or names.functions.len != program.functions.count()) return error.InvalidNames;

    var lower = try @import("render.zig").initializeAnalyzed(allocator, backing, program, facts, scratch);

    lower.type_names = names.types;
    lower.function_modules = names.functions;
    lower.shared_types = true;

    return lower;
}
