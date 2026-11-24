const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const target = @import("../call/target.zig");
const Layout = @import("layout.zig");
const Diagnostic = @import("../expression.zig").Diagnostic;
const generated = @import("rx_options").generated_graph;

pub const Value = union(enum) { resolved: struct { types: zx.ir.TypeStorage, fields: []const zx.ir.TypeId }, diagnostic: Diagnostic };

pub fn resolve(allocator: std.mem.Allocator, temporary: std.mem.Allocator, owner: []const u8, layout: Layout, base: zx.ir.TypeTable, aliases: []const zx.ir.Export) std.mem.Allocator.Error!Value {
    var parsed = try frontend.parseModule(temporary, layout.text, owner);

    defer parsed.deinit();

    if (parsed.diagnostic()) |issue| return .{ .diagnostic = try mapped(temporary, layout, issue) };

    return switch (parsed) {
        .native => |native| native: {
            const program = native.value.parsed.ast;

            if (program.imports.len != 0 or program.constants.len != 0 or program.body != null or program.contracts.len != 0 or program.has_store) break :native invalid(temporary, layout);

            break :native resolveDeclarations(allocator, temporary, layout, base, aliases, frontend.type_views.Native{ .items = program.declarations });
        },
        .indexed => |indexed| if (comptime @TypeOf(indexed) != void) indexed: {
            const output = indexed.output;

            if (comptime generated) {
                const admission = @import("../project/contracts/validate.zig").indexed(indexed.source, output, layout.names, layout.ends);

                if (!admission.valid) break :indexed invalid(temporary, layout);

                break :indexed resolveIndexed(allocator, temporary, layout, base, aliases, indexed.source, output, admission.mismatch);
            }

            if (output.imports.len != 0 or output.constants.len != 0 or output.body != null or output.contracts.len != 0 or output.has_store) break :indexed invalid(temporary, layout);

            break :indexed resolveDeclarations(allocator, temporary, layout, base, aliases, frontend.type_views.Indexed(@TypeOf(output)){ .source = indexed.source, .storage = output });
        } else unreachable,
    };
}

fn resolveIndexed(allocator: std.mem.Allocator, temporary: std.mem.Allocator, layout: Layout, base: zx.ir.TypeTable, aliases: []const zx.ir.Export, text: []const u8, output: anytype, mismatch: ?usize) std.mem.Allocator.Error!Value {
    var types = try frontend.type_table.storage(allocator, base);
    const fields = try temporary.alloc(zx.ir.TypeId, layout.fields.len);
    var scratch = std.heap.ArenaAllocator.init(temporary);

    defer scratch.deinit();

    const request: frontend.type_batch.Request = .{
        .allocator = allocator,
        .target = &types,
        .ids = fields,
        .aliases = aliases,
        .store = .{ .mismatch = mismatch, .ends = layout.ends, .expressions = layout.expressions },
    };

    if (try frontend.type_batch.resolve(&scratch, request, text, output)) |issue| {
        return .{ .diagnostic = try mapped(temporary, layout, issue) };
    }

    return .{ .resolved = .{ .types = types, .fields = fields } };
}

fn resolveDeclarations(allocator: std.mem.Allocator, temporary: std.mem.Allocator, layout: Layout, base: zx.ir.TypeTable, aliases: []const zx.ir.Export, view: anytype) std.mem.Allocator.Error!Value {
    if (view.declarations().count() != layout.fields.len) return invalid(temporary, layout);

    const storage = if (comptime @hasField(@TypeOf(view), "storage")) .{ .types = view.storage.types, .type_order = view.storage.type_order } else .{};
    const resolving = if (comptime @hasField(@TypeOf(view), "storage")) frontend.type_views.Indexed(@TypeOf(storage)){ .source = view.source, .storage = storage } else frontend.type_views.Native{ .items = &.{} };
    var reporter: zx.Reporter = .{};
    var types = frontend.types{ .allocator = allocator, .reporter = &reporter, .declarations = &.{}, .aliases = aliases, .items = try frontend.type_table.storage(allocator, base) };

    types.initialize() catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .diagnostic = try mapped(temporary, layout, reporter.diagnostic.?) };
    };

    const fields = try temporary.alloc(zx.ir.TypeId, layout.fields.len);
    var declarations = view.declarations().iterator();

    for (fields, 0..) |*field, index| {
        const declaration = declarations.next().?;

        if (declaration.name.span.start != layout.nameStart(index) or !std.mem.eql(u8, declaration.name.text, layout.names[index])) return invalid(temporary, layout);

        const id = types.resolveView(resolving, declaration.value) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return .{ .diagnostic = try mapped(temporary, layout, reporter.diagnostic.?) };
        };

        if (id == frontend.types.scalarId(.void)) {
            const offset = layout.typeStart(index);

            return .{ .diagnostic = try mapped(temporary, layout, .{ .code = .type_mismatch, .span = .{ .start = offset, .end = offset }, .message = "Store fields cannot have void type" }) };
        }

        field.* = id;
    }

    return .{ .resolved = .{ .types = types.items, .fields = fields } };
}

fn invalid(allocator: std.mem.Allocator, layout: Layout) std.mem.Allocator.Error!Value {
    const offset = layout.typeStart(0);

    return .{ .diagnostic = try mapped(allocator, layout, .{ .code = .syntax, .span = .{ .start = offset, .end = offset }, .message = "Field.type must contain exactly one ZX type expression" }) };
}

fn mapped(allocator: std.mem.Allocator, layout: Layout, issue: zx.Diagnostic) std.mem.Allocator.Error!Diagnostic {
    const position = if (comptime generated) locate(layout, issue.span.start) else seedLocation(layout, issue.span.start);
    const attribute = target.attribute(layout.fields[position.field].*, "type");
    const location = rx.attributeLocation(attribute, position.relative) orelse attribute.value_location;

    return .{ .location = location, .issue = .{ .code = issue.code, .span = .{ .start = location.offset, .end = location.offset }, .message = try allocator.dupe(u8, issue.message) } };
}

const Location = struct { field: usize, relative: usize };

fn locate(layout: Layout, offset: usize) Location {
    const rule = @import("generated_rx_store_type_diagnostic");
    const input: std.meta.Child(rule.Input) = .{ .ends = layout.ends, .expressions = layout.expressions, .offset = offset };
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const position = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    return .{ .field = @intCast(position.field), .relative = @intCast(position.relative) };
}

fn seedLocation(layout: Layout, offset: usize) Location {
    var low: usize = 0;
    var high = layout.fields.len;

    while (low < high) {
        const middle = low + (high - low) / 2;

        if (layout.typeStart(middle) <= offset) low = middle + 1 else high = middle;
    }

    const field = low -| 1;

    return .{ .field = field, .relative = @min(offset -| layout.typeStart(field), layout.expressions[field].len) };
}

pub fn contextDiagnostic(allocator: std.mem.Allocator, layout: Layout, message: []const u8) std.mem.Allocator.Error!Diagnostic {
    return mapped(allocator, layout, .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = message });
}
