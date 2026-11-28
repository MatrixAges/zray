const std = @import("std");
const generated = @import("generated");
const Input = std.meta.Child(generated.Input);
const Output = generated.Output;
const AbiSpan = std.meta.Child(std.meta.Child(@FieldType(Input, "comments")));
const AbiImport = std.meta.Child(std.meta.Child(@FieldType(Input, "imports")));
const AbiBoundary = std.meta.Child(std.meta.Child(@FieldType(Input, "boundaries")));
const AbiEdit = std.meta.Child(std.meta.Child(std.meta.Child(@FieldType(Input, "edits"))));
pub const Span = struct { start: u64, end: u64 };
pub const Import = struct { path: []const u8, type_only: bool, exported: bool, start: u64, end: u64 };

pub fn check(
    allocator: std.mem.Allocator,
    source: []const u8,
    comments_input: []const Span,
    imports_input: []const Import,
    declarations_input: []const Span,
    constants_input: []const Span,
    function_start: u64,
    boundaries_input: anytype,
) std.mem.Allocator.Error!?Span {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const output = try execute(arena.allocator(), false, source, comments_input, imports_input, declarations_input, constants_input, function_start, boundaries_input);

    return if (output.has_edits) .{ .start = output.first_start, .end = output.first_end } else null;
}

pub fn format(
    allocator: std.mem.Allocator,
    source: []const u8,
    comments_input: []const Span,
    imports_input: []const Import,
    declarations_input: []const Span,
    constants_input: []const Span,
    function_start: u64,
    boundaries_input: anytype,
) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const output = try execute(arena.allocator(), true, source, comments_input, imports_input, declarations_input, constants_input, function_start, boundaries_input);

    return allocator.dupe(u8, output.formatted);
}

pub fn formatEdits(allocator: std.mem.Allocator, source: []const u8, edits: anytype) std.mem.Allocator.Error![]u8 {
    if (edits.len == 0) return allocator.dupe(u8, source);

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    const values = try temporary.alloc(AbiEdit, edits.len);
    const references = try temporary.alloc(*const AbiEdit, edits.len);

    for (edits, values, references) |edit, *value, *reference| {
        value.* = .{ .start = edit.span.start, .end = edit.span.end, .replacement = edit.replacement };
        reference.* = value;
    }

    const output = try run(temporary, &.{
        .apply = true,
        .edits = references,
        .source = source,
        .comments = &.{},
        .imports = &.{},
        .declarations = &.{},
        .constants = &.{},
        .function_start = 0,
        .boundaries = &.{},
    });

    return std.mem.concat(allocator, u8, output.parts.?);
}

fn execute(
    temporary: std.mem.Allocator,
    apply: bool,
    source: []const u8,
    comments_input: []const Span,
    imports_input: []const Import,
    declarations_input: []const Span,
    constants_input: []const Span,
    function_start: u64,
    boundaries_input: anytype,
) std.mem.Allocator.Error!Output {
    const comments = try wrapSpans(temporary, comments_input);
    const declarations = try wrapSpans(temporary, declarations_input);
    const constants = try wrapSpans(temporary, constants_input);
    const imports = try wrapImports(temporary, imports_input);
    const boundaries = try wrapBoundaries(temporary, boundaries_input);

    return run(temporary, &.{
        .apply = apply,
        .edits = null,
        .source = source,
        .comments = comments,
        .imports = imports,
        .declarations = declarations,
        .constants = constants,
        .function_start = function_start,
        .boundaries = boundaries,
    });
}

fn run(temporary: std.mem.Allocator, input: *const Input) std.mem.Allocator.Error!Output {
    return generated.executeIn(temporary, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

fn wrapSpans(allocator: std.mem.Allocator, items: []const Span) std.mem.Allocator.Error![]const *const AbiSpan {
    const values = try allocator.alloc(AbiSpan, items.len);
    const pointers = try allocator.alloc(*const AbiSpan, items.len);

    for (items, values, pointers) |item, *value, *slot| {
        value.* = .{ .start = item.start, .end = item.end };
        slot.* = value;
    }

    return pointers;
}

fn wrapImports(allocator: std.mem.Allocator, items: []const Import) std.mem.Allocator.Error![]const *const AbiImport {
    const values = try allocator.alloc(AbiImport, items.len);
    const pointers = try allocator.alloc(*const AbiImport, items.len);

    for (items, values, pointers) |item, *value, *slot| {
        value.* = .{
            .path = item.path,
            .type_only = item.type_only,
            .exported = item.exported,
            .start = item.start,
            .end = item.end,
        };

        slot.* = value;
    }

    return pointers;
}

fn wrapBoundaries(allocator: std.mem.Allocator, items: anytype) std.mem.Allocator.Error![]const *const AbiBoundary {
    const values = try allocator.alloc(AbiBoundary, items.len);
    const pointers = try allocator.alloc(*const AbiBoundary, items.len);

    for (items, values, pointers) |item, *value, *slot| {
        value.* = .{
            .left = item.left,
            .right = item.right,
            .left_start = item.left_start,
            .right_end = item.right_end,
            .adjacent = item.adjacent,
            .same_kind = item.same_kind,
            .same_shape = item.same_shape,
        };

        slot.* = value;
    }

    return pointers;
}
