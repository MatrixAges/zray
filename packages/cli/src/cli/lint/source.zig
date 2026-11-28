const std = @import("std");
const compiler = @import("compiler");
const lint = @import("lint");
const rx = @import("rx");
const zx = @import("zx");
const Compile = @import("../compile.zig");
const layouts = @import("cli_abi").layouts.@"zig:lint_workflow_host";
const Issue = layouts.SourceIssue;
const state = @import("../sources/effects.zig").state;
const Error = std.mem.Allocator.Error;

pub fn check(context: Compile.Context, source: []const u8) !Compile.Status {
    var arena = std.heap.ArenaAllocator.init(context.allocator);

    defer arena.deinit();

    const path = context.options.input;
    var parsed: ?rx.document.Parsed = null;
    const document = &parsed;

    defer rx.document.release(&parsed);

    const outcome = try @import("cli_source").lint_source.executeIn(arena.allocator(), &.{
        .document = @ptrCast(&document),
        .input_path = path,
        .source = source,
        .maximum_lines = context.options.max_lines orelse lint.length.default_maximum,
    });

    return report(context.stderr, path, outcome);
}

pub fn report(writer: *std.Io.Writer, path: []const u8, outcome: anytype) !Compile.Status {
    if (outcome.status == .Unformatted) try writer.print("{s}: {s}\n", .{ path, lint.source.formatting_required });
    if (outcome.diagnostic) |message| try writer.print("{s}: {s}", .{ path, message });
    if (outcome.issue) |issue| try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ path, issue.line, issue.column, issue.code, issue.message });

    return if (outcome.status == .Valid) .success else .failed;
}

fn issueRow(allocator: std.mem.Allocator, line: usize, column: usize, code: []const u8, message: []const u8) Error!*const Issue {
    const row = try allocator.create(Issue);

    row.* = .{ .line = line, .column = column, .code = code, .message = try allocator.dupe(u8, message) };

    return row;
}

pub fn parseLintRx(allocator: std.mem.Allocator, handle: *const anyopaque, source: []const u8) Error!?*const Issue {
    const parsed = state(?rx.document.Parsed, handle);
    parsed.* = try rx.document.parse(allocator, source, true);

    if (parsed.*.?.value != .diagnostic) return null;

    const issue = parsed.*.?.value.diagnostic;

    return try issueRow(allocator, issue.location.line, issue.location.column, @tagName(issue.code), issue.message);
}

pub fn validateLintRx(allocator: std.mem.Allocator, handle: *const anyopaque, path: []const u8) Error!?*const Issue {
    const parsed = state(?rx.document.Parsed, handle);
    var checked = try rx.validateView(allocator, path, rx.document.schemaRoot(&parsed.*.?));

    defer checked.deinit();

    if (checked.value != .diagnostic) return null;

    const issue = checked.value.diagnostic;

    return try issueRow(allocator, issue.location.line, issue.location.column, @tagName(issue.code), issue.message);
}

pub fn checkLintRxValues(allocator: std.mem.Allocator, handle: *const anyopaque, path: []const u8) Error!?*const Issue {
    const parsed = state(?rx.document.Parsed, handle);
    const node = rx.document.schemaRoot(&parsed.*.?);
    const diagnostic = (try @import("rx_analysis").expression.checkValues(allocator, node, path)) orelse return null;

    defer diagnostic.issue.deinit();

    return try issueRow(allocator, diagnostic.location.line, diagnostic.location.column, @tagName(diagnostic.issue.code), diagnostic.issue.message);
}

pub fn formatLintRx(allocator: std.mem.Allocator, handle: *const anyopaque, source: []const u8) Error![]const u8 {
    const parsed = state(?rx.document.Parsed, handle);

    return rx.document.formatParsed(allocator, source, parsed);
}

pub fn checkLintZx(allocator: std.mem.Allocator, source: []const u8, path: []const u8) Error!?*const Issue {
    const diagnostic = (try compiler.checkSource(allocator, source, path)) orelse return null;

    defer diagnostic.deinit();

    const location = zx.source.locate(source, diagnostic.span.start);

    return try issueRow(allocator, location.line, location.column, @tagName(diagnostic.code), diagnostic.message);
}

pub fn formatLintZx(allocator: std.mem.Allocator, source: []const u8, path: []const u8) Error![]const u8 {
    const formatted = try compiler.format(allocator, source, path);

    return formatted.source;
}
