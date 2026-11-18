const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const project = @import("../project.zig");
const sources = @import("../sources.zig");

pub fn validate(io: std.Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8, config_path: ?[]const u8, modules: []const @import("rx").ModuleSource, calls: []const Selection, writer: *std.Io.Writer) !bool {
    var loaded = project.load(io, allocator, path, config_path) catch |err| {
        if (err == error.OutOfMemory) return err;

        try writer.print("{s}: {s}\n", .{ config_path orelse "pkg.yaml", @errorName(err) });

        return false;
    };

    if (loaded.diagnostic) |message| {
        try writer.print("{s}\n", .{message});

        return false;
    }

    var parse_cache = compiler.project.ParseCache{ .allocator = allocator };

    defer parse_cache.deinit();

    var libraries = @import("../library/inputs.zig"){ .allocator = allocator };

    defer libraries.deinit();

    const detected = sources.readDetectingRx(io, allocator, source, loaded.project, &parse_cache, null, &libraries) catch |err| {
        if (err == error.OutOfMemory) return err;

        try writer.print("{s}: source loading: {s}\n", .{ path, @errorName(err) });

        return false;
    };

    const inputs = detected.sources;
    loaded.project.compiled_libraries = libraries.libraries.items;

    const default_call = for (calls) |call| {
        if (call.member == null) break true;
    } else false;

    if (calls.len == 0 or detected.has_rx) {
        var signed = try compiler.project.analyzeSignaturesWithCache(allocator, inputs, &.{path}, loaded.project, &parse_cache);

        defer signed.deinit();

        if (signed.value == .diagnostic) return report(writer, inputs, signed.value.diagnostic);

        for (signed.value.data.modules) |*module| {
            if (!std.mem.eql(u8, module.path, path)) continue;
            if (!try checkNamed(writer, calls, module.signature.members)) return false;

            break;
        }

        if (!default_call) return true;

        for (signed.value.data.modules) |module| {
            if (!module.signature.has_deferred_source) continue;

            const delegated = module.signature.deferred_source;

            const registered = for (modules) |source_module| {
                const absolute = try std.fs.path.resolve(allocator, &.{ loaded.project.root_dir, source_module.path });

                defer allocator.free(absolute);

                if (std.mem.eql(u8, delegated, absolute)) break true;
            } else false;

            if (!registered) {
                try writer.print("{s}: default re-export target is missing from the RX module collection\n", .{path});
            }

            return registered;
        }
    }

    var analyzed = try compiler.analyzeProjectWithCache(allocator, inputs, loaded.project, &parse_cache);

    defer analyzed.deinit();

    if (analyzed.value == .diagnostic) return report(writer, inputs, analyzed.value.diagnostic);

    for (analyzed.modules) |*module| {
        if (!std.mem.eql(u8, module.path, path)) continue;
        if (!try checkNamed(writer, calls, module.reexports.functions)) return false;

        break;
    }

    if (default_call and analyzed.value.ir.type_only) {
        try writer.print("{s}: Call.fn requires an executable ZX module with a default function\n", .{path});

        return false;
    }

    return true;
}

fn report(writer: *std.Io.Writer, inputs: []const compiler.project.Source, issue: anytype) !bool {
    const index = issue.source_index orelse 0;
    const location = zx.source.locate(inputs[index].original orelse inputs[index].source, issue.span.start);

    try writer.print("{s}:{d}:{d}: {t}: {s}\n", .{ inputs[index].path, location.line, location.column, issue.code, issue.message });

    return false;
}

pub const Selection = struct { owner: []const u8, location: @import("rx").ast.Location, member: ?[]const u8 };

fn checkNamed(writer: *std.Io.Writer, calls: []const Selection, members: anytype) !bool {
    for (calls) |call| {
        const selected = call.member orelse continue;

        const found = for (members) |*member| {
            if (!std.mem.eql(u8, member.name, selected)) continue;
            if (comptime @hasField(@TypeOf(member.*), "id")) break member.id != null;

            break member.kind == .callable and !member.has_store;
        } else false;

        if (found) continue;

        try writer.print("{s}:{d}:{d}: module: ZX source does not export the selected callable function '{s}'\n", .{ call.owner, call.location.line, call.location.column, selected });

        return false;
    }

    return true;
}

pub fn indexCalls(allocator: std.mem.Allocator, graph: *const @import("rx_analysis").project.source_graph.Graph, modules: []const @import("rx").ModuleSource, calls: []std.ArrayList(Selection)) !void {
    const edges = graph.modules.items(.dependencies);

    for (modules, edges[graph.sources.zx_count..graph.sources.rx_end]) |module, dependencies| {
        var references = module.indexedReferences() orelse unreachable;

        for (dependencies) |edge| {
            if (edge.reference != .call) continue;

            const entry = while (references.len != 0) {
                const last = references[references.len - 1];
                references = references[0 .. references.len - 1];

                if (last.role == .Call) break last;
            } else unreachable;

            if (entry.target != .Function) continue;

            const attribute = entry.attribute.?;
            const member = if (edge.named) compiler.project.module_path.callMember(attribute.value).? else null;

            try calls[edge.target.source].append(allocator, .{ .owner = module.path, .location = attribute.value_location, .member = member });
        }
    }
}
