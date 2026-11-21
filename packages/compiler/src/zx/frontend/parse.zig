const std = @import("std");
const zx = @import("zx");
const Parser = @import("parser.zig");
const lex = @import("lexer").lex;
const compact = @import("compact_output.zig");
const diagnostic = @import("diagnostic.zig");
const retention = @import("retention/host.zig");

pub const Parsed = struct {
    source: []const u8,
    file_name: []const u8,
    lexed: zx.syntax.Lexed,
    ast: zx.ast.Program,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: union(enum) { parsed: Parsed, diagnostic: zx.Diagnostic },
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub const ModuleResult = @import("module_result.zig").Result;

pub fn parse(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8) std.mem.Allocator.Error!Result {
    var scratch = zx.Arena.init(compact.scratch_backing);

    defer scratch.deinit();

    const result = try parseWithMode(false, allocator, &scratch, source, file_name);

    return result.native;
}

pub fn parseModule(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8) std.mem.Allocator.Error!ModuleResult {
    var scratch = zx.Arena.init(compact.scratch_backing);

    defer scratch.deinit();

    return parseModuleIn(allocator, &scratch, source, file_name);
}

/// Parses with the generated parser's working memory in `scratch`, which is reset afterwards but keeps its pages, so a
/// thread parsing module after module reuses them instead of mapping and faulting fresh ones.
pub fn parseModuleIn(allocator: std.mem.Allocator, scratch: *zx.Arena, source: []const u8, file_name: []const u8) std.mem.Allocator.Error!ModuleResult {
    return parseWithMode(true, allocator, scratch, source, file_name);
}

const scratch_limit = 16 << 20;

fn parseWithMode(comptime retain_indexed: bool, allocator: std.mem.Allocator, scratch: *zx.Arena, source: []const u8, file_name: []const u8) std.mem.Allocator.Error!ModuleResult {
    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    var reporter: zx.Reporter = .{};
    const owned_source = try arena.allocator().dupe(u8, source);
    const owned_name = try arena.allocator().dupe(u8, file_name);

    if (@import("parser_options").generated_parser) {
        const generated = @import("generated_parser");
        const adapter = @import("program_adapter/root.zig");

        defer scratch.reset(scratch_limit);

        const output = generated.executeIn(scratch.allocator(), owned_source) catch |err| {
            const issue = try diagnostic.generatedFailure(arena.allocator(), "parser", err);

            return .{ .native = .{ .arena = arena, .value = .{ .diagnostic = issue } } };
        };

        if (output.diagnostic) |issue| {
            const published = try diagnostic.publish(arena.allocator(), issue);

            return .{ .native = .{ .arena = arena, .value = .{ .diagnostic = published } } };
        }

        if (retain_indexed) {
            const retained = try retention.retain(@import("generated_program_retention_size"), allocator, owned_source, output);

            return .{ .indexed = .{
                .arena = arena,
                .syntax_arena = retained.arena,
                .source = owned_source,
                .file_name = owned_name,
                .output = retained.output,
            } };
        }

        const tree = try adapter.convert(arena.allocator(), owned_source, output);
        const tokens = try adapter.lexed(arena.allocator(), output);

        return .{ .native = .{ .arena = arena, .value = .{ .parsed = .{ .source = owned_source, .file_name = owned_name, .lexed = tokens, .ast = tree } } } };
    }

    const lexed = lex(arena.allocator(), owned_source, &reporter) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .native = .{ .arena = arena, .value = .{ .diagnostic = reporter.diagnostic.? } } };
    };

    var parser = Parser{ .allocator = arena.allocator(), .source = owned_source, .tokens = lexed.tokens, .reporter = &reporter };

    const tree = parser.program() catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return .{ .native = .{ .arena = arena, .value = .{ .diagnostic = reporter.diagnostic.? } } };
    };

    return .{ .native = .{ .arena = arena, .value = .{ .parsed = .{ .source = owned_source, .file_name = owned_name, .lexed = lexed, .ast = tree } } } };
}
