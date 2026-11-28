const std = @import("std");
const zx = @import("zx");
const syntax = zx.syntax.borrow;
const rule = @import("lint_layout");

pub const Projection = struct {
    allocator: std.mem.Allocator,
    raw_tokens: []const rule.RawSpan,
    raw_comments: []const rule.RawSpan,
    ops: std.ArrayList(rule.Op) = .empty,
    failed: bool = false,
    pub fn init(allocator: std.mem.Allocator, _: []const u8, tokens: anytype, comments: anytype) std.mem.Allocator.Error!Projection {
        const raw_tokens = try allocator.alloc(rule.RawSpan, tokens.len);

        errdefer allocator.free(raw_tokens);

        const raw_comments = try allocator.alloc(rule.RawSpan, comments.len);

        for (0..tokens.len, raw_tokens) |index, *target| {
            const span = zx.syntax.header.span(syntax.item(tokens, index).span);

            target.* = .{ .start = @intCast(span.start), .end = @intCast(span.end) };
        }

        for (0..comments.len, raw_comments) |index, *target| {
            const span = zx.syntax.header.span(syntax.item(comments, index));

            target.* = .{ .start = @intCast(span.start), .end = @intCast(span.end) };
        }

        return .{ .allocator = allocator, .raw_tokens = raw_tokens, .raw_comments = raw_comments };
    }

    pub fn excludeStart(self: *Projection, offset: usize, block: bool) void {
        self.record(.ExcludeStart, offset, 0, 0, block);
    }

    pub fn excludeEnding(self: *Projection, end: usize, block: bool) void {
        self.record(.ExcludeEnding, 0, end, 0, block);
    }

    pub fn multilineEnding(self: *Projection, end: usize) void {
        self.record(.MultilineEnding, 0, end, 0, false);
    }

    pub fn boundary(self: *Projection, offset: usize) void {
        self.record(.Boundary, offset, 0, 0, false);
    }

    pub fn list(self: *Projection, start: usize, count: usize) void {
        if (count >= 2) self.record(.List, start, 0, count, false);
    }
    pub fn condition(self: *Projection, span: zx.Span) void {
        self.record(.Condition, span.start, span.end, 0, false);
    }

    pub fn excludeRange(self: *Projection, span: zx.Span) void {
        self.record(.ExcludeRange, span.start, span.end, 0, false);
    }

    fn record(self: *Projection, kind: @FieldType(rule.Op, "kind"), start: usize, end: usize, count: usize, flag: bool) void {
        if (self.failed) return;

        self.ops.append(self.allocator, .{ .kind = kind, .start = start, .end = end, .count = count, .flag = flag }) catch {
            self.failed = true;
        };
    }
};
