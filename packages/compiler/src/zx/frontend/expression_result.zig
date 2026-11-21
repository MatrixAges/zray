const std = @import("std");
const zx = @import("zx");
const parser = @import("parse_expression.zig");
const Order = @import("syntax/program/order.zig");
pub const indexed_enabled = @import("parser_options").generated_parser;
pub const View = if (indexed_enabled) @import("syntax/program.zig").View(@import("generated_expression").Output) else void;

pub const Indexed = if (indexed_enabled) struct {
    arena: std.heap.ArenaAllocator,
    row_arena: zx.Arena,
    syntax_arena: zx.Arena,
    source: []const u8,
    file_name: []const u8,
    output: @import("generated_expression").Output,
    order_words: ?[]const u64 = null,
    pub fn prepareOrder(self: *@This()) std.mem.Allocator.Error!void {
        if (self.order_words != null) return;

        const prepared = try Order.prepare(self.arena.allocator(), self.output);

        self.order_words = prepared.words;
    }

    pub fn view(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!View {
        if (self.order_words) |words| return View.fromOrder(self.source, self.output, Order.borrow(words, self.output));

        return View.init(allocator, self.source, self.output);
    }
} else void;

pub const Result = union(enum) {
    native: parser.Result,
    indexed: Indexed,
    pub fn deinit(self: *@This()) void {
        switch (self.*) {
            .native => |*result| result.deinit(),
            .indexed => |*result| if (indexed_enabled) {
                result.syntax_arena.deinit();
                result.row_arena.deinit();
                result.arena.deinit();
            } else unreachable,
        }

        self.* = undefined;
    }

    pub fn diagnostic(self: *const @This()) ?zx.Diagnostic {
        return switch (self.*) {
            .native => |result| if (result.value == .diagnostic) result.value.diagnostic else null,
            .indexed => null,
        };
    }
};
