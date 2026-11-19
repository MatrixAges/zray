const std = @import("std");
const zx = @import("zx");
const Conditions = @import("../../verification/conditions.zig");
const port_paths = @import("../../verification/ports.zig");
const values = @import("../../verification/terms.zig");
const Terms = @import("terms.zig");
const generated = @import("parser_options").generated_parser;
const bindings = @import("construction/bindings.zig");
const scratch_buffer_size = 32 * 1024;
pub const ir = @import("ir.zig");
pub const validate = @import("validate.zig").validate;

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: union(enum) { module: ir.Module, diagnostic: zx.Diagnostic },
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn generate(allocator: std.mem.Allocator, program: zx.ir.Program) std.mem.Allocator.Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    if (try @import("frontend").validateIr(allocator, program)) |issue| return .{ .arena = arena, .value = .{ .diagnostic = issue } };

    var symbolic = std.heap.ArenaAllocator.init(allocator);

    defer symbolic.deinit();

    var buffer: [scratch_buffer_size]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, symbolic.allocator());
    const scratch = memory.allocator();
    var reporter: zx.Reporter = .{};
    var evaluation_scratch = zx.Arena.init(allocator);

    defer evaluation_scratch.deinit();

    var conditions = Conditions{ .allocator = scratch, .scratch = &evaluation_scratch, .program = program, .reporter = &reporter };

    const model = conditions.model(arena.allocator()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .arena = arena, .value = .{ .diagnostic = reporter.diagnostic orelse diagnostic("unsupported hardware symbolic model") } };
    };

    const module = build(arena.allocator(), scratch, program, model) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .arena = arena, .value = .{ .diagnostic = diagnostic("invalid or oversized typed hardware expression") } };
    };

    return .{ .arena = arena, .value = .{ .module = module } };
}

fn build(allocator: std.mem.Allocator, scratch: std.mem.Allocator, program: zx.ir.Program, model: Conditions.Model) !ir.Module {
    var terms = Terms{ .allocator = allocator, .scratch = scratch };

    defer terms.variables.deinit(scratch);
    defer terms.cache.deinit(scratch);

    const symbol_count = model.inputs.len + model.definitions.len;

    try terms.variables.ensureTotalCapacity(scratch, @intCast(symbol_count));
    try terms.cache.ensureTotalCapacity(scratch, @intCast(model.definitions.len));

    const inputs = try allocator.alloc(ir.Port, model.inputs.len);

    try terms.nodes.ensureTotalCapacity(allocator, @min(symbol_count, Terms.max_nodes));

    for (model.inputs, inputs, 0..) |input, *port, index| {
        const kind = try portType(program.typeOf(input.type_id));
        const sort = kind.sort;
        const id = try terms.add(.{ .sort = sort, .value = .{ .input = index } });

        if (comptime !generated) terms.variables.putAssumeCapacity(input.symbol, id);

        port.* = .{ .name = input.symbol, .path = input.path, .sort = sort, .signed = kind.signed, .node = id };
    }

    if (comptime generated) try bindings.bindInputs(&terms, model.inputs);

    var origin_file: ?[]const u8 = null;

    for (0..model.definitions.len) |row| {
        const definition = model.definitions.get(row);

        if (origin_file == null or !std.mem.eql(u8, origin_file.?, definition.origin.file_name))
            origin_file = try allocator.dupe(u8, definition.origin.file_name);

        terms.origin = .{ .file_name = origin_file.?, .span = definition.origin.span };
        const id = try terms.parse(definition.expression);

        if (comptime generated) {
            try bindings.publish(&terms, definition.name, definition.width, id);
        } else {
            const sort = ir.Sort{ .width = if (definition.width == 0) 1 else definition.width, .boolean = definition.width == 0 };

            if (!sort.equal(terms.nodes.items[@backingInt(id)].sort)) return error.InvalidHardwareTerm;

            terms.variables.putAssumeCapacity(definition.name, id);
        }
    }

    terms.origin = null;

    var outputs: std.ArrayList(ir.Port) = .empty;

    try flatten(&terms, program, program.output_type, model.output.value, "out", &outputs);

    const safe = try terms.parse(model.output.safe);

    if (!terms.nodes.items[@backingInt(safe)].sort.boolean) return error.InvalidHardwareTerm;

    return .{ .nodes = terms.nodes.items, .inputs = inputs, .outputs = outputs.items, .safe = safe };
}

fn flatten(terms: *Terms, program: zx.ir.Program, type_id: zx.ir.TypeId, value: values.Value, path: []const u8, ports: *std.ArrayList(ir.Port)) Terms.Error!void {
    const target = program.typeOf(type_id);

    if (target == .object or target == .tuple) {
        const count = if (target == .object) target.object.len else target.tuple.len;

        if (value != .fields or value.fields.len != count) return error.InvalidHardwareTerm;

        for (value.fields, 0..) |field, index| {
            const child_path = try port_paths.fieldPath(terms.allocator, path, if (target == .object) target.object.at(index).name else null, index);

            try flatten(terms, program, if (target == .object) target.object.at(index).type_id else target.tuple.at(index), field, child_path, ports);
        }

        return;
    }

    if (target == .scalar and target.scalar == .void) return;
    if (value != .scalar) return error.InvalidHardwareTerm;

    const kind = try portType(target);
    const sort = kind.sort;
    const id = try terms.parse(value.scalar);

    if (!sort.equal(terms.nodes.items[@backingInt(id)].sort)) return error.InvalidHardwareTerm;

    try ports.append(terms.allocator, .{ .name = try port_paths.name(terms.allocator, ports.items.len, true), .path = path, .sort = sort, .signed = kind.signed, .node = id });
}

fn portType(target: zx.ir.Type) !struct { sort: ir.Sort, signed: bool } {
    if (values.integer(target)) |integer| return .{ .sort = .{ .width = integer.width }, .signed = integer.signed };
    if (target == .scalar and target.scalar == .bool) return .{ .sort = .{ .width = 1, .boolean = true }, .signed = false };

    return error.InvalidHardwareTerm;
}

fn diagnostic(message: []const u8) zx.Diagnostic {
    return .{ .code = .unsupported, .span = .{ .start = 0, .end = 0 }, .message = message };
}
