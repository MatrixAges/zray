const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const target = @import("../call/target.zig");
const Layout = @import("layout.zig");
const Schedule = @import("prepare/schedule.zig");
const Diagnostic = @import("../expression.zig").Diagnostic;
const generated = @import("rx_options").generated_graph;

pub const Value = union(enum) { resolved: struct { types: zx.ir.TypeStorage, fields: []const zx.ir.TypeId }, diagnostic: Diagnostic };

pub fn resolve(allocator: std.mem.Allocator, temporary: std.mem.Allocator, owner: []const u8, layout: Layout, context: frontend.Context, aliases: []const zx.ir.Export) std.mem.Allocator.Error!Value {
    inline for (comptime Schedule.steps(.TypeContext)) |step| {
        const issue: ?[]const u8 = switch (step) {
            .Done => null,
            .CheckTypes => if (context.types.count() != 0 and !frontend.validateTypes(context.types)) "invalid shared Store type table" else null,
            .CheckNativeTypes => if (!frontend.native_context.valid(context.types, context.native_modules)) "invalid shared native module table" else null,
            .CheckNominalTypes => if (!try frontend.validateNominalTypes(context.types, context.nominal_types)) "invalid shared nominal type table" else null,
            .CheckAliases => if (!validAliases(aliases, context.types.count())) "Store type alias is missing from the shared type table" else null,
            else => unreachable,
        };

        if (issue) |message| return .{ .diagnostic = try mapped(temporary, layout, .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = message }) };
    }

    var parsed = try frontend.parseModule(temporary, layout.text, owner);

    defer parsed.deinit();

    if (parsed.diagnostic()) |issue| return .{ .diagnostic = try mapped(temporary, layout, issue) };

    return switch (parsed) {
        .native => |native| native: {
            const program = native.value.parsed.ast;

            if (program.imports.len != 0 or program.constants.len != 0 or program.body != null or program.contracts.len != 0 or program.has_store) break :native invalid(temporary, layout);

            break :native resolveDeclarations(allocator, temporary, layout, context.types, aliases, frontend.type_views.Native{ .items = program.declarations }, null);
        },
        .indexed => |indexed| if (comptime @TypeOf(indexed) != void) indexed: {
            const output = indexed.output;

            const mismatch = if (comptime generated) admit: {
                const admission = @import("../project/contracts/validate.zig").indexed(indexed.source, output, layout.names, layout.ends);

                if (!admission.valid) break :indexed invalid(temporary, layout);

                break :admit admission.mismatch;
            } else seed: {
                if (output.imports.len != 0 or output.constants.len != 0 or output.body != null or output.contracts.len != 0 or output.has_store) break :indexed invalid(temporary, layout);

                break :seed null;
            };

            break :indexed resolveDeclarations(allocator, temporary, layout, context.types, aliases, frontend.type_views.Indexed(@TypeOf(output)){ .source = indexed.source, .storage = output }, mismatch);
        } else unreachable,
    };
}

fn resolveDeclarations(allocator: std.mem.Allocator, temporary: std.mem.Allocator, layout: Layout, base: zx.ir.TypeTable, aliases: []const zx.ir.Export, view: anytype, mismatch: ?usize) std.mem.Allocator.Error!Value {
    const checked = comptime generated and @hasField(@TypeOf(view), "storage");

    if (!checked and view.declarations().count() != layout.fields.len) return invalid(temporary, layout);

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
        var id: zx.ir.TypeId = undefined;

        inline for (comptime Schedule.steps(.FieldType)) |step| {
            switch (step) {
                .Done => {},
                .CheckDeclaration => if (comptime checked) {
                    if (mismatch == index) return invalid(temporary, layout);
                } else {
                    if (declaration.name.span.start != layout.nameStart(index) or !std.mem.eql(u8, declaration.name.text, layout.names[index])) return invalid(temporary, layout);
                },
                .ResolveFieldType => id = types.resolveView(resolving, declaration.value) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;

                    return .{ .diagnostic = try mapped(temporary, layout, reporter.diagnostic.?) };
                },
                .CheckFieldType => if (id == frontend.types.scalarId(.void)) {
                    const offset = layout.typeStart(index);

                    return .{ .diagnostic = try mapped(temporary, layout, .{ .code = .type_mismatch, .span = .{ .start = offset, .end = offset }, .message = "Store fields cannot have void type" }) };
                },
                .RecordFieldType => field.* = id,
                else => unreachable,
            }
        }
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

fn validAliases(aliases: []const zx.ir.Export, count: usize) bool {
    if (aliases.len == 0) return true;

    if (comptime generated) {
        const rule = @import("generated_rx_store_type_aliases");
        const rows = @import("zx").memory.borrowNamedRows("type_id", aliases);
        const input: std.meta.Child(rule.Input) = .{ .aliases = @ptrCast(&rows), .length = rows.len, .type_count = count };
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
    }

    for (aliases) |alias| if (@backingInt(alias.type_id) >= count) return false;

    return true;
}
