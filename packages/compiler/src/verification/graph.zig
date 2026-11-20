const std = @import("std");
const zx = @import("zx");
const terms = @import("terms.zig");
const Self = @This();
const generated = @import("parser_options").generated_parser;

const limits = if (generated) @import("generated_verification_graph_constants").@"zx.constants" else struct {
    const max_steps = 1000000;
    const step_limit_message = "symbolic execution exceeds 1000000 evaluation steps";
};

pub const Origin = struct { file_name: []const u8, span: zx.Span };
pub const Definition = struct { name: []const u8, expression: []const u8, width: u16, origin: Origin };
pub const Definitions = std.MultiArrayList(Definition);

allocator: std.mem.Allocator,
reporter: *zx.Reporter,
definitions: Definitions = .empty,
declaration_payload_bytes: usize = 0,
index: if (generated) []u64 else std.StringHashMapUnmanaged(usize) = if (generated) &.{} else .empty,
calls: @import("call_cache.zig").Cache = .{},
steps: usize = 0,
pub fn step(self: *Self, span: zx.Span) zx.Error!void {
    if (self.steps >= limits.max_steps) return self.reporter.fail(.unsupported, span, limits.step_limit_message);

    self.steps += 1;
}

pub fn bind(self: *Self, expression: []const u8, width: u16, origin: Origin) zx.Error![]const u8 {
    if (comptime !generated) return self.bindSeed(expression, width, origin);

    const admission = @import("generated_verification_graph_admit");
    const publication = @import("generated_verification_graph_publish");
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const input: std.meta.Child(admission.Input) = .{
        .keys = self.definitions.items(.expression),
        .key = expression,
        .widths = self.definitions.items(.width),
        .width = width,
        .buckets = @ptrCast(&self.index),
        .capacity = self.index.len,
    };

    const selected = zx.columns.invoke(admission.executeValue, empty.allocator(), &input) catch unreachable;

    switch (selected.action) {
        .Atom => return expression,
        .Reuse => return self.definitions.items(.name)[@intCast(selected.position)],
        .WidthMismatch => return error.InvalidSource,
        .Limit => return self.reporter.fail(.unsupported, origin.span, limits.definition_limit_message),
        .Append => {},
    }

    try self.definitions.ensureUnusedCapacity(self.allocator, 1);

    const rows = self.definitions.slice();
    const resized = selected.capacity != self.index.len;
    const buckets = if (resized) try self.allocator.alloc(u64, @intCast(selected.capacity)) else self.index;

    errdefer if (resized) self.allocator.free(buckets);

    if (resized) @memset(buckets, 0);

    const request: std.meta.Child(publication.Input) = .{
        .origin = &.{
            .count = rows.len,
            .file = origin.file_name,
            .previous = if (rows.len == 0) null else rows.items(.origin)[rows.len - 1].file_name,
        },
        .index = &.{
            .keys = rows.items(.expression),
            .key = expression,
            .buckets = @ptrCast(&buckets),
            .capacity = buckets.len,
            .position = selected.position,
            .resized = resized,
        },
    };

    const identity = zx.columns.invoke(publication.executeValue, self.allocator, &request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    self.appendDefinition(.{
        .name = identity.name,
        .expression = expression,
        .width = width,
        .origin = .{ .file_name = identity.file, .span = origin.span },
    });

    if (resized) {
        self.allocator.free(self.index);

        self.index = buckets;
    }

    return identity.name;
}

fn bindSeed(self: *Self, expression: []const u8, width: u16, origin: Origin) zx.Error![]const u8 {
    if (expression.len == 0 or expression[0] != '(') return expression;

    if (self.index.get(expression)) |index| {
        const definition = self.definitions.get(index);

        if (definition.width != width) return error.InvalidSource;

        return definition.name;
    }

    if (self.definitions.len >= 100000) return self.reporter.fail(.unsupported, origin.span, "symbolic graph exceeds 100000 definitions");

    const owned_origin = Origin{ .file_name = try self.allocator.dupe(u8, origin.file_name), .span = origin.span };
    const name = try std.fmt.allocPrint(self.allocator, "term_{d}", .{self.definitions.len});

    try self.definitions.ensureUnusedCapacity(self.allocator, 1);
    try self.index.put(self.allocator, expression, self.definitions.len);

    self.appendDefinition(.{ .name = name, .expression = expression, .width = width, .origin = owned_origin });

    return name;
}

fn appendDefinition(self: *Self, definition: Definition) void {
    self.definitions.appendAssumeCapacity(definition);

    self.declaration_payload_bytes +|= definition.name.len +| definition.expression.len;
}

pub fn declarationCapacity(self: *const Self) usize {
    // The longest sort uses five digits for a bit-vector width. Names and
    // expressions are already accounted for in declaration_payload_bytes.
    const max_overhead = "(define-fun  () (_ BitVec 65535) )\n".len;

    return self.declaration_payload_bytes +| (self.definitions.len *| max_overhead);
}

/// Every composite is assembled from evaluations whose scalar leaves are already bound.
pub fn retain(self: *Self, program: zx.ir.Program, type_id: zx.ir.TypeId, input: terms.Value, span: zx.Span) zx.Error!terms.Value {
    if (input == .fields) return input;

    const width = terms.symbolicWidth(program.typeOf(type_id)) orelse return self.reporter.fail(.unsupported, span, "symbolic graph requires boolean, enum or fixed-width integer values");

    return .{ .scalar = try self.bind(input.scalar, width, .{ .file_name = program.file_name, .span = span }) };
}

pub fn select(self: *Self, program: zx.ir.Program, type_id: zx.ir.TypeId, condition: []const u8, yes: terms.Value, no: terms.Value, span: zx.Span) zx.Error!terms.Value {
    if (yes == .scalar and no == .scalar) {
        const selected = try terms.choose(self.allocator, condition, yes.scalar, no.scalar);

        return self.retain(program, type_id, .{ .scalar = selected }, span);
    }

    if (yes != .fields or no != .fields or yes.fields.len != no.fields.len) return error.InvalidSource;
    if (yes.fields.len == 0 or yes.fields.ptr == no.fields.ptr) return yes;

    const target = program.typeOf(type_id);
    const fields = try self.allocator.alloc(terms.Value, yes.fields.len);

    for (fields, yes.fields, no.fields, 0..) |*field, left, right, index| {
        const child = if (target == .object) target.object.at(index).type_id else target.tuple.at(index);

        field.* = try self.select(program, child, condition, left, right, span);
    }

    return .{ .fields = fields };
}

pub fn writeDeclarations(self: *Self, output: *std.Io.Writer, start: usize, end: usize) zx.Error!void {
    if (start == end) return;

    const rows = self.definitions.slice().subslice(start, end - start);

    if (comptime generated) {
        const rule = @import("generated_verification_graph_declarations");

        const input: std.meta.Child(rule.Input) = .{
            .writer = @ptrCast(output),
            .expressions = rows.items(.expression),
            .names = rows.items(.name),
            .widths = rows.items(.width),
        };

        zx.columns.invoke(rule.executeValue, self.allocator, &input) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
    } else {
        for (0..rows.len) |row| {
            const definition = rows.get(row);
            const sort = if (definition.width == 0) "Bool" else try std.fmt.allocPrint(self.allocator, "(_ BitVec {d})", .{definition.width});

            output.print("(define-fun {s} () {s} {s})\n", .{ definition.name, sort, definition.expression }) catch return error.OutOfMemory;
        }
    }
}
