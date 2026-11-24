const std = @import("std");
const rx = @import("rx");

pub fn entry(io: std.Io, allocator: std.mem.Allocator, scratch: std.mem.Allocator, path: []const u8, project: ?[]const u8, writer: *std.Io.Writer) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    return @import("load.zig").check(io, arena.allocator(), allocator, scratch, path, project, writer);
}

pub fn sources(io: std.Io, allocator: std.mem.Allocator, paths: []const []const u8, writer: *std.Io.Writer) !bool {
    const documents = try allocator.alloc(rx.TextSource, paths.len);
    var loaded: usize = 0;

    defer {
        for (documents[0..loaded]) |source| allocator.free(source.source);

        allocator.free(documents);
    }

    for (paths, documents) |path, *source| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
            try writer.print("{s}: {s}\n", .{ path, @errorName(err) });

            return false;
        };

        source.* = .{ .path = path, .source = text };
        loaded += 1;
    }

    return validate(allocator, documents, writer);
}

fn validate(allocator: std.mem.Allocator, documents: []const rx.TextSource, writer: *std.Io.Writer) !bool {
    var result = try rx.parseModules(allocator, documents);

    defer result.deinit();

    if (result.value == .diagnostic) {
        const diagnostic = result.value.diagnostic;

        return report(writer, documents[diagnostic.source_index].path, diagnostic.issue);
    }

    return true;
}

pub fn report(writer: *std.Io.Writer, path: []const u8, issue: rx.Diagnostic) !bool {
    try writer.print("{s}:{d}:{d}: {t}: {s}\n", .{ path, issue.location.line, issue.location.column, issue.code, issue.message });

    return false;
}
