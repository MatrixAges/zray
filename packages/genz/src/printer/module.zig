const std = @import("std");
pub const available = @import("genz_options").generated;
const zx = @import("zx");
const generated = @import("generated_printer_module_range");
const Input = std.meta.Child(generated.Input);
const Ast = std.meta.Child(std.meta.Elem(@FieldType(Input, "ast")));

pub fn render(allocator: std.mem.Allocator, workspace: std.mem.Allocator, comptime Module: type, module: anytype) std.mem.Allocator.Error![]u8 {
    var output: zx.memory.ByteWriter = .{ .allocator = allocator };

    defer output.deinit();

    try write(&output, workspace, Module, module);

    return output.finish();
}

/// Source AST payloads stay borrowed until the unified printer has finished.
pub fn write(output: *zx.memory.ByteWriter, workspace: std.mem.Allocator, comptime Module: type, module: anytype) std.mem.Allocator.Error!void {
    const expression_views = if (@hasField(Module, "context")) legacy: {
        const Context = std.meta.Child(@FieldType(Module, "context"));
        const expressions = zx.columns.view(std.meta.Child(@FieldType(Context, "expressions")), module.context.expressions);
        const forms = zx.columns.view(std.meta.Child(@FieldType(Context, "forms")), module.context.forms);

        if (@hasField(Module, "expression_forms")) {
            const additional = zx.columns.view(std.meta.Child(@FieldType(Module, "expression_forms")), module.expression_forms);

            break :legacy if (@hasField(Module, "extra"))
                .{ expressions, forms, zx.columns.view(std.meta.Child(@FieldType(Module, "extra")), module.extra), additional }

            else
                .{ expressions, forms, additional };
        }

        break :legacy if (@hasField(Module, "extra"))
            .{ expressions, forms, zx.columns.view(std.meta.Child(@FieldType(Module, "extra")), module.extra) }
        else
            .{ expressions, forms };
    } else .{zx.columns.view(std.meta.Child(@FieldType(Module, "expressions")), module.expressions)};

    const declarations = zx.columns.view(std.meta.Child(@FieldType(Module, "declarations")), module.declarations);
    const expression_columns = project(std.meta.Child(@FieldType(Ast, "expressions")), expression_views);
    const statement_columns = project(std.meta.Child(@FieldType(Ast, "statements")), if (@hasField(Module, "statements")) .{zx.columns.view(std.meta.Child(@FieldType(Module, "statements")), module.statements)} else .{});
    const declaration_columns = project(std.meta.Child(@FieldType(Ast, "declarations")), .{declarations});
    const field_columns = project(std.meta.Child(@FieldType(Ast, "fields")), if (@hasField(Module, "fields")) .{zx.columns.view(std.meta.Child(@FieldType(Module, "fields")), module.fields)} else .{});
    const arm_columns = project(std.meta.Child(@FieldType(Ast, "arms")), if (@hasField(Module, "arms")) .{zx.columns.view(std.meta.Child(@FieldType(Module, "arms")), module.arms)} else .{});

    const ast: Ast = .{
        .expressions = &expression_columns,
        .statements = &statement_columns,
        .declarations = &declaration_columns,
        .fields = &field_columns,
        .arms = &arm_columns,
    };

    const input: Input = .{
        .ast = &.{&ast},
        .first = if (@hasField(Module, "first")) module.first else 0,
        .count = if (@hasField(Module, "count")) module.count else null,
    };

    const chunks = zx.columns.invoke(generated.executeValue, workspace, &input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    try writeChunks(output, chunks orelse return error.OutOfMemory);
}

pub fn writeChunks(output: *zx.memory.ByteWriter, chunks: []const []const u8) std.mem.Allocator.Error!void {
    return writeGroups(output, &.{chunks});
}

pub fn writeGroups(output: *zx.memory.ByteWriter, groups: []const []const []const u8) std.mem.Allocator.Error!void {
    var size: usize = 0;

    for (groups) |chunks| {
        for (chunks) |chunk| size = std.math.add(usize, size, chunk.len) catch return error.OutOfMemory;
    }

    try output.buffer.ensureUnusedCapacity(output.allocator, size);

    for (groups) |chunks| {
        for (chunks) |chunk| output.buffer.appendSliceAssumeCapacity(chunk);
    }
}

fn project(comptime Target: type, sources: anytype) Target {
    @setEvalBranchQuota(100_000);

    var result: Target = undefined;

    inline for (@typeInfo(Target).@"struct".field_names) |name| {
        const Field = @FieldType(Target, name);

        @field(result, name) = found: {
            inline for (sources) |source| {
                if (@hasField(@TypeOf(source), name)) break :found zx.columns.slice(Field, @field(source, name));
            }

            break :found &.{};
        };
    }

    return result;
}
