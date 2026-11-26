const std = @import("std");
const generated = @import("generated");
const Input = std.meta.Child(generated.Input);
const AbiSpan = std.meta.Child(std.meta.Child(@FieldType(Input, "comments")));
const AbiImport = std.meta.Child(std.meta.Child(@FieldType(Input, "imports")));
const AbiBoundary = std.meta.Child(std.meta.Child(@FieldType(Input, "boundaries")));
pub const Span = struct { start: u64, end: u64 };
pub const Import = struct { path: []const u8, type_only: bool, exported: bool, start: u64, end: u64 };
pub const Edit = struct { start: usize, end: usize, replacement: []const u8 };

pub fn plan(
    allocator: std.mem.Allocator,
    source: []const u8,
    comments_input: []const Span,
    imports_input: []const Import,
    declarations_input: []const Span,
    constants_input: []const Span,
    function_start: u64,
    boundaries_input: anytype,
) std.mem.Allocator.Error![]const Edit {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    const comments = try wrapSpans(temporary, comments_input);
    const declarations = try wrapSpans(temporary, declarations_input);
    const constants = try wrapSpans(temporary, constants_input);
    const imports = try wrapImports(temporary, imports_input);
    const boundaries = try wrapBoundaries(temporary, boundaries_input);

    const output = generated.executeIn(temporary, &.{
        .source = source,
        .comments = comments,
        .imports = imports,
        .declarations = declarations,
        .constants = constants,
        .function_start = function_start,
        .boundaries = boundaries,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    const result = try allocator.alloc(Edit, output.len);
    var initialized: usize = 0;

    errdefer {
        for (result[0..initialized]) |item| allocator.free(item.replacement);

        allocator.free(result);
    }

    for (output, 0..) |item, index| {
        result[index] = .{
            .start = @intCast(item.start),
            .end = @intCast(item.end),
            .replacement = try allocator.dupe(u8, item.replacement),
        };

        initialized += 1;
    }

    return result;
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
        value.* = .{ .left = item.left, .right = item.right, .separate = item.separate };
        slot.* = value;
    }

    return pointers;
}
