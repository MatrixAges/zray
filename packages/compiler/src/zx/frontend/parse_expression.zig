const std = @import("std");
const zx = @import("zx");
const Parser = @import("parser.zig");
const lex = @import("lexer").lex;
const compact = @import("compact_output.zig");
const diagnostic = @import("diagnostic.zig");
const retention = @import("retention/host.zig");
const lexical = @import("retention/lexical.zig");

pub const Parsed = struct {
    source: []const u8,
    file_name: []const u8,
    lexed: zx.syntax.Lexed,
    expression: *const zx.ast.Expression,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: union(enum) { parsed: Parsed, diagnostic: zx.Diagnostic },
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub const InputResult = @import("expression_result.zig").Result;

pub fn parse(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8) std.mem.Allocator.Error!Result {
    const result = try parseWithMode(false, true, allocator, source, file_name);

    return result.native;
}

pub fn parseInput(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8) std.mem.Allocator.Error!InputResult {
    return parseWithMode(true, true, allocator, source, file_name);
}

/// The caller keeps the source and filename alive until it releases the parse result.
pub fn parseBorrowedInput(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8) std.mem.Allocator.Error!InputResult {
    return parseWithMode(true, false, allocator, source, file_name);
}

fn parseWithMode(comptime indexed: bool, copy_input: bool, allocator: std.mem.Allocator, source: []const u8, file_name: []const u8) std.mem.Allocator.Error!InputResult {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    var reporter: zx.Reporter = .{};
    const temporary = arena.allocator();
    const owned_source = if (copy_input) try temporary.dupe(u8, source) else source;
    const owned_name = if (copy_input) try temporary.dupe(u8, file_name) else file_name;

    if (@import("parser_options").generated_parser) {
        const generated = @import("generated_expression");
        const adapter = @import("program_adapter/root.zig");
        var scratch = zx.Arena.init(compact.scratch_backing);

        defer scratch.deinit();

        const output = lexical.parse(generated, if (indexed) .none else .full, scratch.allocator(), null, owned_source) catch |err| {
            const issue = try diagnostic.generatedFailure(temporary, "expression parser", err);

            return .{ .native = .{ .arena = arena, .value = .{ .diagnostic = issue } } };
        };

        if (output.diagnostic) |issue| {
            const published = try diagnostic.publish(temporary, issue);

            return .{ .native = .{ .arena = arena, .value = .{ .diagnostic = published } } };
        }

        if (indexed) {
            const retained = try retention.retain(@import("generated_expression_retention_size"), allocator, owned_source, output);

            return .{ .indexed = .{
                .arena = arena,
                .syntax_arena = retained.arena,
                .source = owned_source,
                .file_name = owned_name,
                .output = retained.output,
            } };
        }

        const expression = try adapter.expression(temporary, owned_source, output);
        const tokens = try adapter.lexed(temporary, output);

        return .{ .native = .{ .arena = arena, .value = .{ .parsed = .{ .source = owned_source, .file_name = owned_name, .lexed = tokens, .expression = expression } } } };
    }

    const lexed = lex(temporary, owned_source, &reporter) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .native = .{ .arena = arena, .value = .{ .diagnostic = reporter.diagnostic.? } } };
    };

    var parser = Parser{ .allocator = temporary, .source = owned_source, .tokens = lexed.tokens, .reporter = &reporter };

    const expression = parser.expression(0) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .native = .{ .arena = arena, .value = .{ .diagnostic = reporter.diagnostic.? } } };
    };

    if (parser.current().kind != .eof) return .{ .native = .{ .arena = arena, .value = .{ .diagnostic = .{
        .code = .syntax,
        .span = parser.current().span,
        .message = "expected the end of the expression",
    } } } };

    return .{ .native = .{ .arena = arena, .value = .{ .parsed = .{ .source = owned_source, .file_name = owned_name, .lexed = lexed, .expression = expression } } } };
}
