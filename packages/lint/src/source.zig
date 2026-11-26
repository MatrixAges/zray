const std = @import("std");
const zx = @import("zx");
const spacing = @import("spacing.zig");
const Header = zx.syntax.header;
pub const formatting_required = "import order, blank lines or indentation require formatting";

pub const Input = struct {
    source: []const u8,
    comments: []const zx.Span,
    program: zx.ast.Program,
};

pub fn checkBarrel(view: anytype, has_store: bool) ?zx.Diagnostic {
    for (0..view.importCount()) |index| {
        const item = view.importAt(index);

        if (!item.exported) return barrelIssue(item.span);
    }

    if (view.declarationCount() != 0) return barrelIssue(view.declarationAt(0).span);
    if (view.constantCount() != 0) return barrelIssue(view.constantAt(0).span);

    if (view.hasBody()) {
        const start = view.functionStart();

        return barrelIssue(.{ .start = start, .end = start });
    }

    if (has_store) return barrelIssue(.{ .start = 0, .end = 0 });

    return null;
}

fn barrelIssue(span: zx.Span) zx.Diagnostic {
    return .{
        .code = .style,
        .span = span,
        .message = "index.zx may only re-export from other modules; move declarations to a named ZX file",
    };
}

pub fn check(allocator: std.mem.Allocator, input: Input) std.mem.Allocator.Error!?zx.Diagnostic {
    return checkView(allocator, input.source, input.comments, Header.Native{ .program = input.program }, input.program.contracts, input.program.body);
}

pub fn checkHeader(allocator: std.mem.Allocator, source: []const u8, comments: anytype, view: anytype) std.mem.Allocator.Error!?zx.Diagnostic {
    return checkView(allocator, source, comments, view, @as([]const zx.ast.Contract, &.{}), @as(?zx.ast.Block, null));
}

pub fn checkView(allocator: std.mem.Allocator, source: []const u8, comments: anytype, view: anytype, contracts: anytype, body: anytype) std.mem.Allocator.Error!?zx.Diagnostic {
    if (@import("root.zig").checkSourceStyle(source, view, contracts, body)) |issue| return issue;
    if (comptime @import("lint_options").seed) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const prepared = try prepareView(arena.allocator(), source, comments, view, body);

    const span = try @import("lint_source").check(
        arena.allocator(),
        source,
        prepared.comments,
        prepared.imports,
        prepared.declarations,
        prepared.constants,
        view.functionStart(),
        prepared.boundaries,
    ) orelse return null;

    return .{
        .code = .spacing,
        .span = .{ .start = @intCast(span.start), .end = @intCast(span.end) },
        .message = "import order or blank lines do not match built-in rules; run zxc fmt",
    };
}

pub fn format(allocator: std.mem.Allocator, input: Input) std.mem.Allocator.Error![]u8 {
    return formatView(allocator, input.source, input.comments, Header.Native{ .program = input.program }, input.program.body);
}

pub fn formatView(allocator: std.mem.Allocator, source: []const u8, comments: anytype, view: anytype, body: anytype) std.mem.Allocator.Error![]u8 {
    if (comptime @import("lint_options").seed) return allocator.dupe(u8, source);

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const prepared = try prepareView(arena.allocator(), source, comments, view, body);

    return @import("lint_source").format(
        allocator,
        source,
        prepared.comments,
        prepared.imports,
        prepared.declarations,
        prepared.constants,
        view.functionStart(),
        prepared.boundaries,
    );
}

fn PreparedView() type {
    const rule = @import("lint_source");

    return struct {
        comments: []const rule.Span,
        imports: []const rule.Import,
        declarations: []const rule.Span,
        constants: []const rule.Span,
        boundaries: []const spacing.Boundary,
    };
}

fn prepareView(temporary: std.mem.Allocator, source: []const u8, comments: anytype, view: anytype, body: anytype) std.mem.Allocator.Error!PreparedView() {
    const rule = @import("lint_source");
    const comment_spans = try temporary.alloc(rule.Span, comments.len);

    for (comments, comment_spans) |position, *slot| {
        const span = Header.span(position);

        slot.* = .{ .start = span.start, .end = span.end };
    }

    const imports = try temporary.alloc(rule.Import, view.importCount());

    for (imports, 0..) |*slot, index| {
        const item = view.importAt(index);

        slot.* = .{
            .path = item.path,
            .type_only = item.kind == .type_only,
            .exported = item.exported,
            .start = item.span.start,
            .end = item.span.end,
        };
    }

    const declarations = try temporary.alloc(rule.Span, view.declarationCount());

    for (declarations, 0..) |*slot, index| {
        const span = view.declarationAt(index).span;

        slot.* = .{ .start = span.start, .end = span.end };
    }

    const constants = try temporary.alloc(rule.Span, view.constantCount());

    for (constants, 0..) |*slot, index| {
        const span = view.constantAt(index).span;

        slot.* = .{ .start = span.start, .end = span.end };
    }

    const boundaries = if (body) |value| try spacing.collectBody(temporary, source, value) else &.{};

    return .{
        .comments = comment_spans,
        .imports = imports,
        .declarations = declarations,
        .constants = constants,
        .boundaries = boundaries,
    };
}
