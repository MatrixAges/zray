const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const Graph = @import("../inference/types.zig");
const Prepared = @import("prepare.zig");
const SourceMap = @import("../source_map.zig");
const Source = @import("contracts/source.zig");

pub const Ports = struct {
    owners: []const u64 = &.{},
    types: []const zx.ir.TypeId = &.{},
    pub const Pair = struct {
        owner: usize,
        input: zx.ir.TypeId,
        output: zx.ir.TypeId,
        next: usize,
    };

    pub fn at(self: Ports, start: usize) ?Pair {
        if (start == self.owners.len) return null;

        if (comptime !@import("rx_options").generated_graph) {
            const owner = self.owners[start];
            var end = start + 2;

            while (end < self.owners.len and self.owners[end] == owner) : (end += 2) {}

            return .{ .owner = @intCast(owner), .input = self.types[end - 2], .output = self.types[end - 1], .next = end };
        }

        const rule = @import("generated_rx_args_ports");
        const Input = std.meta.Child(rule.Input);
        const input: Input = .{ .owners = self.owners, .types = @ptrCast(self.types), .start = start };
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const selected = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        return .{
            .owner = @intCast(selected.owner),
            .input = @fromBackingInt(selected.input),
            .output = @fromBackingInt(selected.output),
            .next = @intCast(selected.next),
        };
    }
};

pub fn resolve(temporary: std.mem.Allocator, graph: *Graph, modules: []const Prepared.Module, source_map: SourceMap) zx.Error!Ports {
    var source = Source{ .allocator = temporary };

    try source.collect(modules);

    const owners = source.entries.items(.module);

    if (owners.len == 0) return .{};

    var parsed = try frontend.parseModule(temporary, source.text, modules[@intCast(owners[0])].source.path);

    defer parsed.deinit();

    if (parsed.diagnostic()) |issue| return fail(graph, source, source_map, issue);

    switch (parsed) {
        .native => |native| {
            const program = native.value.parsed.ast;
            const view = frontend.type_views.Native{ .items = program.declarations };

            if (!validSeed(source, view, program.imports.len, program.constants.len, program.contracts.len, program.body != null, program.has_store)) return invalid(graph, source, source_map);

            return resolveDeclarations(graph, modules, source, source_map, view);
        },
        .indexed => |indexed| if (comptime @TypeOf(indexed) != void) {
            const output = indexed.output;
            const view = frontend.type_views.Indexed(@TypeOf(output)){ .source = indexed.source, .storage = output };

            const valid = if (@import("rx_options").generated_graph)
                validIndexed(source, indexed.source, output)
            else
                validSeed(source, view, output.imports.len, output.constants.len, output.contracts.len, output.body != null, output.has_store);

            if (!valid) return invalid(graph, source, source_map);

            return resolveDeclarations(graph, modules, source, source_map, view);
        } else unreachable,
    }
}

fn validIndexed(source: Source, text: []const u8, output: anytype) bool {
    const admission = @import("contracts/validate.zig").indexed(text, output, source.names, null);

    return admission.valid and admission.mismatch == null;
}

fn validSeed(source: Source, view: anytype, imports: usize, constants: usize, contracts: usize, body: bool, store: bool) bool {
    if (imports != 0 or constants != 0 or contracts != 0 or body or store) return false;

    const declarations = view.declarations();

    if (declarations.count() != source.names.len) return false;

    var iterator = declarations.iterator();

    for (source.names) |name| {
        if (!std.mem.eql(u8, iterator.next().?.name.text, name)) return false;
    }

    return true;
}

fn resolveDeclarations(graph: *Graph, modules: []const Prepared.Module, source: Source, source_map: SourceMap, view: anytype) zx.Error!Ports {
    const storage = if (comptime @hasField(@TypeOf(view), "storage")) .{ .types = view.storage.types, .type_order = view.storage.type_order } else .{};

    const resolving = if (comptime @hasField(@TypeOf(view), "storage"))
        frontend.type_views.Indexed(@TypeOf(storage)){ .source = view.source, .storage = storage }

    else
        frontend.type_views.Native{ .items = &.{} };

    const previous_reporter = graph.types.reporter;
    const previous_aliases = graph.types.aliases;
    var reporter: zx.Reporter = .{};
    graph.types.reporter = &reporter;

    defer {
        graph.types.reporter = previous_reporter;
        graph.types.aliases = previous_aliases;
    }

    const owners = source.entries.items(.module);
    const types = try source.allocator.alloc(zx.ir.TypeId, owners.len);
    var declarations = view.declarations().iterator();
    var start: usize = 0;

    while (start < owners.len) {
        const owner: usize = @intCast(owners[start]);
        var end = start + 1;

        while (end < owners.len and owners[end] == owner) : (end += 1) {}

        graph.types.aliases = modules[owner].type_imports;

        for (types[start..end]) |*type_id| {
            const declaration = declarations.next().?;

            type_id.* = graph.types.resolveView(resolving, declaration.value) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;

                return fail(graph, source, source_map, reporter.diagnostic.?);
            };
        }

        start = end;
    }

    return .{ .owners = owners, .types = types };
}

fn invalid(graph: *Graph, source: Source, source_map: SourceMap) zx.Error {
    return graph.reporter.fail(.syntax, source.span(source_map, 0), "Args declarations must contain only ZX types");
}

fn fail(graph: *Graph, source: Source, source_map: SourceMap, issue: zx.Diagnostic) zx.Error {
    return graph.reporter.fail(issue.code, source.span(source_map, issue.span.start), try graph.allocator.dupe(u8, issue.message));
}
