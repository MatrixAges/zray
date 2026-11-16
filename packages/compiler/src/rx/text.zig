const std = @import("std");
const dsl = @import("dsl");
const modules = @import("modules.zig");
const generated = @import("rx_options").generated_graph;
pub const Source = struct { path: []const u8, source: []const u8, packages: []const @import("frontend").project.Package = &.{} };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    dependency_order: []const usize = &.{},
    parsed: []dsl.XmlResult,
    inputs: []const modules.Source = &.{},
    selected: []const modules.Source = &.{},
    validated: ?modules.Result = null,
    value: union(enum) { data: []const modules.Module, diagnostic: modules.Diagnostic },
    pub fn deinit(self: *Result) void {
        if (self.validated) |*validated| validated.deinit();
        for (self.parsed) |*parsed| parsed.deinit();

        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn parseModules(allocator: std.mem.Allocator, sources: []const Source) std.mem.Allocator.Error!Result {
    return parse(allocator, sources, null);
}

/// Validates all inputs, then selects the entry and its dependencies in input order.
pub fn parseReachableModules(allocator: std.mem.Allocator, sources: []const Source, entry: []const u8) !Result {
    var selection: modules.Selection = .{ .path = entry };
    var result = try parse(allocator, sources, &selection);

    errdefer result.deinit();

    if (result.value == .data) {
        const owned = result.arena.allocator();

        if (comptime generated) {
            const marks = selection.marks orelse return error.MissingParserEntry;
            const selected = try owned.alloc(modules.Source, std.mem.countScalar(u32, marks, 1));
            var count: usize = 0;

            for (result.inputs, marks) |*source, mark| {
                if (mark == 0) continue;

                selected[count] = source.*;
                count += 1;
            }

            result.selected = selected;
        } else {
            result.selected = try @import("dependency_graph/seed_selection.zig").reachable(owned, result.inputs, entry);
        }
    }

    return result;
}

fn parse(allocator: std.mem.Allocator, sources: []const Source, selection: ?*modules.Selection) std.mem.Allocator.Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    var parsed: std.ArrayList(dsl.XmlResult) = .empty;

    errdefer {
        for (parsed.items) |*item| item.deinit();

        arena.deinit();
    }

    const temporary = arena.allocator();
    const inputs = try temporary.alloc(modules.Source, sources.len);

    try parsed.ensureTotalCapacity(temporary, sources.len);

    for (sources, 0..) |source, index| {
        const item = try @import("frontend").parseIndexedXml(allocator, source.source);

        parsed.appendAssumeCapacity(item.xml);

        switch (item.xml.value) {
            .diagnostic => |issue| return .{ .arena = arena, .parsed = parsed.items, .value = .{ .diagnostic = .{ .source_index = index, .issue = issue } } },
            .node => |node| inputs[index] = .{ .path = source.path, .node = node, .packages = source.packages, .references = item.references },
        }
    }

    const validated = try modules.validateSelection(allocator, inputs, selection);

    if (validated.value == .data) {
        for (inputs, parsed.items) |*input, *item| modules.markSchema(input, &item.value.node);
    }

    return .{ .arena = arena, .parsed = parsed.items, .inputs = inputs, .validated = validated, .dependency_order = validated.dependency_order, .value = switch (validated.value) {
        .data => |data| .{ .data = data },
        .diagnostic => |issue| .{ .diagnostic = issue },
    } };
}
