const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const State = @import("state.zig");
const Rows = @import("imports/rows.zig");
const Binding = std.meta.Child(@FieldType(frontend.ResolvedImports, "imports"));
pub const Result = struct { functions: []const Binding, published: []const Binding };

pub fn collect(state: *State, allocator: std.mem.Allocator, header: anytype, index: usize, signature: frontend.project.signature_project.Module, source_text: []const u8) State.Error!Result {
    var bindings: std.ArrayList(Binding) = .empty;
    var published: std.ArrayList(Binding) = .empty;
    const edges = state.graph.modules.items(.dependencies)[index];

    if (edges.len != header.importCount()) return state.fail(.{ .offset = 0, .line = 1, .column = 1 }, "source import declarations do not match the dependency graph");

    var rows: Rows = .{};

    while (rows.next(header)) |import_index| {
        const edge = edges[import_index];
        const item = header.importAt(import_index);

        if (edge.target == .native) continue;

        const dependency = switch (edge.target) {
            .source => |source| source_block: {
                const loaded = state.finished.get(source) orelse return state.fail(edge.locate(source_text), "source function dependency has not been analyzed in its required context");

                break :source_block frontend.project.compiled.Export{ .name = "", .path = "", .function = loaded.function, .types = loaded.exports, .constants = loaded.constant_exports, .members = loaded.members };
            },
            .compiled => |target| try @import("library.zig").load(state, target, edge.location, source_text),
            .native => unreachable,
        };

        const temporary = state.scratch.allocator();
        const binding = frontend.project.import_binding;

        const own: ?Binding = if (dependency.function) |id| own: {
            const row = @backingInt(id);

            break :own .{ .name = "", .id = id, .input_type = @fromBackingInt(state.functions.input_types.items[row]), .output_type = @fromBackingInt(state.functions.output_types.items[row]) };
        } else null;

        const members: binding.Members = .{ .default = if (own) |*value| value else null, .named = dependency.members };
        const symbols = binding.Symbols{ .target = if (edge.target == .source) .source else .compiled, .types = state.types.items.view(), .exports = dependency.types, .constants = dependency.constants, .functions = members.names() };
        var reporter: zx.Reporter = .{};
        const view = frontend.project.import_view.get(header, import_index);

        const selected = binding.select(temporary, state.allocator, view, &symbols, &reporter) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return state.fail(edge.locate(source_text), reporter.diagnostic.?.message);
        };

        if (selected.functions.names.len == 0) continue;

        const destination = if (item.exported) &published else &bindings;
        const prefix = if (item.exported) signature.reexport_functions else signature.function_imports;
        const first = if (destination.items.len == 0) prefix.len else 0;
        const count = std.math.add(usize, first, selected.functions.names.len) catch return error.OutOfMemory;

        try destination.ensureUnusedCapacity(allocator, count);

        destination.appendSliceAssumeCapacity(prefix[0..first]);

        for (selected.functions.names, selected.functions.indices) |name, selected_index| {
            var member = members.at(@intCast(selected_index)).*;

            member.name = try allocator.dupe(u8, name);

            destination.appendAssumeCapacity(member);
        }
    }

    return .{
        .functions = if (bindings.items.len == 0) signature.function_imports else bindings.items,
        .published = if (published.items.len == 0) signature.reexport_functions else published.items,
    };
}
