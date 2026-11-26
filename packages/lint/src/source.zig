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

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const changes = try planView(arena.allocator(), source, comments, view, body);

    return diagnostic(changes);
}

fn diagnostic(changes: []const spacing.Edit) ?zx.Diagnostic {
    if (changes.len == 0) return null;

    return .{ .code = .spacing, .span = changes[0].span, .message = "import order or blank lines do not match built-in rules; run zxc fmt" };
}

pub fn format(allocator: std.mem.Allocator, input: Input) std.mem.Allocator.Error![]u8 {
    return formatView(allocator, input.source, input.comments, Header.Native{ .program = input.program }, input.program.body);
}

pub fn formatView(allocator: std.mem.Allocator, source: []const u8, comments: anytype, view: anytype, body: anytype) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const changes = try planView(arena.allocator(), source, comments, view, body);

    return spacing.format(allocator, source, changes);
}

fn planView(allocator: std.mem.Allocator, source: []const u8, comments: anytype, view: anytype, body: anytype) std.mem.Allocator.Error![]const spacing.Edit {
    if (comptime @import("lint_options").seed) return &.{};

    const rule = @import("lint_source");
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
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

    const planned = try rule.plan(
        allocator,
        source,
        comment_spans,
        imports,
        declarations,
        constants,
        view.functionStart(),
        boundaries,
    );

    defer allocator.free(planned);
    errdefer for (planned) |item| allocator.free(item.replacement);

    const result = try allocator.alloc(spacing.Edit, planned.len);

    for (planned, result) |item, *slot| {
        slot.* = .{
            .span = .{ .start = item.start, .end = item.end },
            .replacement = item.replacement,
        };
    }

    return result;
}
