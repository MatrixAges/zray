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
        self.record(.{ .kind = .ExcludeStart, .start = offset, .flag = block });
    }

    pub fn excludeEnding(self: *Projection, end: usize, block: bool) void {
        self.record(.{ .kind = .ExcludeEnding, .end = end, .flag = block });
    }

    pub fn multilineEnding(self: *Projection, end: usize) void {
        self.record(.{ .kind = .MultilineEnding, .end = end });
    }

    pub fn boundary(self: *Projection, offset: usize) void {
        self.record(.{ .kind = .Boundary, .start = offset });
    }

    pub fn list(self: *Projection, start: usize, count: usize) void {
        if (count >= 2) self.record(.{ .kind = .List, .start = start, .count = count });
    }
    pub fn condition(self: *Projection, span: zx.Span) void {
        self.record(.{ .kind = .Condition, .start = span.start, .end = span.end });
    }

    pub fn excludeRange(self: *Projection, span: zx.Span) void {
        self.record(.{ .kind = .ExcludeRange, .start = span.start, .end = span.end });
    }

    fn record(self: *Projection, op: rule.Op) void {
        if (self.failed) return;

        self.ops.append(self.allocator, op) catch {
            self.failed = true;
        };
    }
};
