const std = @import("std");
const frontend = @import("frontend");
const ir = @import("zx").ir;
const model = @import("root.zig");
const artifact = frontend.project.artifact;
const Types = artifact.type_link.Table;
const equality = frontend.compare_ir.initializer;
const generated = @import("parser_options").generated_parser;
const Self = @This();
pub const Error = Types.Error || artifact.Error || error{ InvalidInitializer, ConflictingInitializer };

allocator: std.mem.Allocator,
scratch: std.mem.Allocator,
types: *Types,
functions: *ir.FunctionStorage,
registry: frontend.project.compiled.InitializerRegistry,
pub fn source(self: *Self, initial: model.Initializer.Borrowed, origins: @FieldType(frontend.AnalysisResult, "nominal_types")) Error!void {
    if (comptime generated) return artifact.source_initializer.publish(self.types, self.scratch, self.functions, &self.registry, initial, origins);

    const program = initial.program;

    if (!try valid(self.scratch, program)) return error.InvalidInitializer;

    const mapping = try self.types.appendFrom(self.scratch, program.types, origins, 0);

    const candidate: ir.Function = .{
        .file_name = initial.identity,
        .input_type = program.input_type,
        .output_type = program.output_type,
        .output_ownership = program.output_ownership,
        .symbols = program.symbols,
        .expressions = program.expressions,
        .body = program.body,
    };

    if (self.registry.find(initial.identity)) |previous| {
        const linked = self.functions.at(@backingInt(previous.function));

        if (!equality.matches(&linked, &candidate, previous.schema_version, initial.schema_version, mapping)) return error.ConflictingInitializer;

        return;
    }

    var nodes = frontend.ArtifactNodes{ .allocator = self.allocator, .types = .{ .mapped = mapping }, .functions = .{ .indexed = &.{} }, .native_modules = .{ .indexed = &.{} } };
    const id: ir.FunctionId = @fromBackingInt(@intCast(self.functions.count()));

    try nodes.appendFunction(self.functions, &candidate, self.scratch);
    try self.registry.merge(self.allocator, &.{.{ .identity = initial.identity, .schema_version = initial.schema_version, .function = id }}, .{ .count = self.functions.count() }, &.{ .local = self.functions }, true);
}

fn valid(scratch: std.mem.Allocator, program: *const ir.Program) std.mem.Allocator.Error!bool {
    if (program.type_only or program.functions.count() != 0 or program.native_modules.count() != 0 or program.stores.count() != 0 or program.contracts.count() != 0) return false;
    if (try frontend.validateIr(scratch, program.*) != null) return false;

    return program.typeOf(program.input_type) == .scalar and
        program.typeOf(program.input_type).scalar == .void and
        program.typeOf(program.output_type) == .object;
}
