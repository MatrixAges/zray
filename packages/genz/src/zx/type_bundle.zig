const std = @import("std");
const zx = @import("zx");
const Lower = @import("lower.zig");
const printer = @import("../render.zig");
const Range = @import("../node/stored.zig").Declarations;

pub fn render(allocator: std.mem.Allocator, self: *Lower) Lower.Error![]u8 {
    if (!@import("genz_options").generated_analysis) {
        const declarations = try @import("type_bundle/seed.zig").declarations(self);
        const stored = try self.builder.nodes.declarations(self.allocator, declarations);

        return printer.renderStoredScoped(allocator, self.workspace, self.builder.nodes, &.{stored});
    }

    const first = self.builder.nodes.declaration_rows.tags.items.len;

    try @import("types.zig").lower(self, null, true);

    const end = self.builder.nodes.declaration_rows.tags.items.len;
    const roots = try appendNamespaces(self, @intCast(end));

    const ranges = [_]Range{
        .{ .start = @intCast(first), .len = @intCast(end - first) },
        roots,
    };

    return printer.renderStoredScoped(allocator, self.workspace, self.builder.nodes, &ranges);
}

fn appendNamespaces(self: *Lower, declaration_base: u32) Lower.Error!Range {
    const generated = @import("generated_native_declarations");
    const Input = std.meta.Child(generated.Input);
    const Modules = std.meta.Child(@FieldType(Input, "modules"));
    const Functions = std.meta.Child(@FieldType(Input, "functions"));
    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    var modules: Modules = undefined;
    var functions: Functions = undefined;

    inline for (@typeInfo(Modules).@"struct".field_names) |name| {
        @field(modules, name) = zx.columns.slice(@FieldType(Modules, name), @field(self.program.native_modules, name));
    }

    inline for (@typeInfo(Functions).@"struct".field_names) |name| {
        @field(functions, name) = zx.columns.slice(@FieldType(Functions, name), @field(self.program.functions, name));
    }

    const input = Input{
        .modules = &modules,
        .functions = &functions,
        .types = @ptrCast(self.types),
        .layouts = @ptrCast(self.layouts),
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .declaration_base = declaration_base,
    };

    const output = generated.executeIn(scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) return error.OutOfMemory;

    @import("../node/import_module.zig").appendBorrowed(self.allocator, self.builder.nodes, std.meta.Child(generated.Output), output) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    return .{ .start = output.root_start, .len = output.root_count };
}
