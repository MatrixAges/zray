const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const Builder = @import("../program/builder.zig");
const inlineValue = @import("../program/expression.zig").inlineValue;
const expression = @import("../expression.zig");
const target = @import("../call/target.zig");
const Layout = @import("layout.zig");
const object = @import("initializer/object.zig");
const span = zx.Span{ .start = 0, .end = 0 };
const input_type = frontend.types.scalarId(.void);
const Value = union(enum) { program: zx.ir.Program, diagnostic: expression.Diagnostic };

const Options = struct {
    owner: []const u8,
    layout: Layout,
    first: u32,
    field_types: []const zx.ir.TypeId,
    types: *zx.ir.TypeStorage,
    native_modules: zx.ir.NativeModuleTable,
    aliases: frontend.expressions.BindingColumns,
};

pub fn compile(allocator: std.mem.Allocator, backing: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Value {
    var scratch = std.heap.ArenaAllocator.init(backing);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const layout = options.layout;
    var fragment: ?u32 = options.first;
    var count: usize = 0;

    while (fragment) |index| : (fragment = layout.next[index]) {
        count += layout.offsets[index + 1] - layout.offsets[index];
    }

    const fields = try frontend.types.Fields.init(allocator, count);
    const names = try temporary.alloc([]const u8, count);
    const evaluation = try temporary.alloc(u32, count);
    var builder = Builder{ .allocator = allocator, .types = options.types.view(), .native_modules = options.native_modules };

    defer builder.linking_scratch.deinit();

    _ = try builder.symbol("in", input_type, span);

    var cursor: usize = 0;
    var invalid_link = false;

    fragment = options.first;

    while (fragment) |index| : (fragment = layout.next[index]) {
        const start = layout.offsets[index];
        const end = layout.offsets[index + 1];

        for (start..end, cursor..) |row, position| {
            const node = layout.fields[row].*;
            const attribute = target.attribute(node, "value");
            const id = options.field_types[row];
            var parsed = try @import("../attribute.zig").parseBorrowed(backing, attribute, options.owner);

            defer parsed.deinit();

            var initial = try expression.compileParsed(backing, &parsed, attribute, .{
                .types = options.types.view(),
                .borrow_types = true,
                .type_storage = options.types,
                .type_allocator = allocator,
                .native_modules = options.native_modules,
                .alias_columns = options.aliases,
                .expected = id,
                .scratch_backing = backing,
            }, false);

            defer initial.deinit();

            if (initial.value == .diagnostic) {
                var issue = initial.value.diagnostic;
                issue.issue = try issue.issue.clone(allocator);

                return .{ .diagnostic = issue };
            }

            const name = try allocator.dupe(u8, target.attribute(node, "name").value);

            names[position] = name;

            fields.set(position, name, id);

            if (!invalid_link) {
                // Finish checking the field expressions before reporting a link failure.
                const evaluated = inlineValue(&builder, initial.value.ir, false) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;

                    invalid_link = true;

                    continue;
                };

                evaluation[position] = @backingInt(evaluated);
            }
        }

        cursor += end - start;
    }

    var reporter: zx.Reporter = .{};

    const program = publish(&builder, options, fields, names, evaluation, invalid_link, &reporter) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        const location = layout.fragments[options.first].location;

        return .{ .diagnostic = .{ .location = location, .issue = try reporter.diagnostic.?.clone(allocator) } };
    };

    return .{ .program = program };
}

fn publish(builder: *Builder, options: Options, fields: frontend.types.Fields, names: []const []const u8, evaluation: []const u32, invalid_link: bool, reporter: *zx.Reporter) zx.Error!zx.ir.Program {
    const allocator = builder.allocator;
    var table = frontend.types{ .allocator = allocator, .reporter = reporter, .declarations = &.{}, .items = options.types.* };
    defer options.types.* = table.items;

    const output = try table.object(fields);

    if (invalid_link) return reporter.fail(.contract, span, "Store initializer expression cannot be linked");

    const root = try object.append(builder, output, names, table.get(output).object.names, evaluation, span);

    var program = zx.ir.Program{
        .file_name = options.owner,
        .types = table.items.view(),
        .native_modules = options.native_modules,
        .symbols = builder.symbols.view(),
        .expressions = builder.expressions.view(),
        .input_type = input_type,
        .output_type = output,
        .body = try zx.ir.ControlBody.fromValues(allocator, &.{.{ .result = root }}),
    };

    program.output_ownership = try frontend.analyzeOwnership(allocator, program, reporter);

    if (try frontend.validateIr(allocator, program)) |issue| return reporter.fail(issue.code, issue.span, issue.message);

    return program;
}
