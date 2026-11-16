const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const Builder = @import("../program/builder.zig");
const inlineValue = @import("../program/expression.zig").inlineValue;
const expression = @import("../expression.zig");
const rx = @import("rx");
const Declarations = @import("../project/declarations.zig");
const Schedule = @import("prepare/schedule.zig");
const Layout = @import("layout.zig");
const object = @import("initializer/object.zig");
const Fields = @import("initializer/fields.zig");
const span = zx.Span{ .start = 0, .end = 0 };
const input_type = frontend.types.scalarId(.void);
const generated = @import("rx_options").generated_graph;
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
    var ranges = Fields.init(&layout, options.first);
    const count = ranges.count;
    const fields = try frontend.types.Fields.init(allocator, count);
    // The Source constructor leaves inputs in declaration order. The seed sorts its fields in place.
    const names = if (comptime generated) fields.names else try temporary.alloc([]const u8, count);
    const evaluation = try temporary.alloc(u32, count);
    var builder = Builder{ .allocator = allocator, .types = options.types.view(), .native_modules = options.native_modules };

    defer builder.linking_scratch.deinit();

    _ = try builder.symbol("in", input_type, span);

    var cursor: usize = 0;
    var invalid_link = false;

    while (ranges.next()) |range| {
        for (range.first..range.end, cursor..) |row, position| {
            const node = layout.fields[row];
            const id = options.field_types[row];
            var field_name: *const rx.ast.Attribute = undefined;
            var field_value: *const rx.ast.Attribute = undefined;
            var parsed: ?frontend.ExpressionInput.Result = null;
            var initial: ?expression.Result = null;

            defer if (parsed) |*value| value.deinit();
            defer if (initial) |*value| value.deinit();

            inline for (comptime Schedule.steps(.Field)) |step| {
                switch (step) {
                    .Done => {},
                    .ReadFieldAttributes => {
                        const attributes = Declarations.attributes(node, .Field);

                        field_name = attributes.first;
                        field_value = attributes.second.?;
                    },
                    .ParseField => parsed = try @import("../attribute.zig").parseBorrowed(backing, field_value.*, options.owner),
                    .CompileField => {
                        initial = try expression.compileParsed(backing, &parsed.?, field_value.*, .{
                            .types = options.types.view(),
                            .borrow_types = true,
                            .type_storage = options.types,
                            .type_allocator = allocator,
                            .native_modules = options.native_modules,
                            .alias_columns = options.aliases,
                            .expected = id,
                            .scratch_backing = backing,
                        }, false);

                        if (initial.?.value == .diagnostic) {
                            var issue = initial.?.value.diagnostic;
                            issue.issue = try issue.issue.clone(allocator);

                            return .{ .diagnostic = issue };
                        }
                    },
                    .RecordField => {
                        const name = try allocator.dupe(u8, field_name.value);

                        if (comptime !generated) names[position] = name;

                        fields.set(position, name, id);
                    },
                    .LinkField => if (!invalid_link) {
                        // Finish checking the remaining fields before reporting a link failure.
                        if (inlineValue(&builder, initial.?.value.ir, false)) |evaluated| {
                            evaluation[position] = @backingInt(evaluated);
                        } else |err| {
                            if (err == error.OutOfMemory) return error.OutOfMemory;

                            invalid_link = true;
                        }
                    },
                    else => unreachable,
                }
            }
        }

        cursor += range.end - range.first;
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

    var output: zx.ir.TypeId = undefined;
    var program: zx.ir.Program = undefined;

    inline for (comptime Schedule.steps(.Program)) |step| {
        switch (step) {
            .Done => {},
            .ResolveObjectType => output = try table.object(fields),
            .CheckLinks => if (invalid_link) return reporter.fail(.contract, span, "Store initializer expression cannot be linked"),
            .BuildProgram => {
                const root = try object.append(builder, output, names, table.get(output).object.names, evaluation, span);

                program = .{
                    .file_name = options.owner,
                    .types = table.items.view(),
                    .native_modules = options.native_modules,
                    .symbols = builder.symbols.view(),
                    .expressions = builder.expressions.view(),
                    .input_type = input_type,
                    .output_type = output,
                    .body = try zx.ir.ControlBody.fromValues(allocator, &.{.{ .result = root }}),
                };
            },
            .AnalyzeOwnership => program.output_ownership = try frontend.analyzeOwnership(allocator, program, reporter),
            .VerifyProgram => if (try frontend.validateIr(allocator, program)) |issue| return reporter.fail(issue.code, issue.span, issue.message),
            else => unreachable,
        }
    }

    return program;
}
