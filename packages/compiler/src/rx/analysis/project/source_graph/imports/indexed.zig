const std = @import("std");
const zx = @import("zx");
const memory = @import("zxc_standard").memory;
const project = @import("frontend").project;
const Collector = @import("../collect.zig");
const position = @import("../position.zig");
const plan = @import("generated_source_graph_import_batch");
const Input = std.meta.Child(plan.Input);
const batch_size = 16;

comptime {
    const Route = project.ImportRoute;

    std.debug.assert(@sizeOf(Route) == @sizeOf(u8));
    std.debug.assert(@backingInt(Route.File) == 0 and @backingInt(Route.Package) == 1);
    std.debug.assert(@backingInt(Route.Intrinsic) == 2 and @backingInt(Route.Interface) == 3);
    std.debug.assert(@backingInt(Route.Invalid) == 4);
}

pub fn collect(collector: *Collector, header: anytype) Collector.Error!void {
    const imports = header.storage.imports;

    if (imports.len == 0) return;

    const names = memory.borrowTextColumn("specifier", collector.dependencies());
    var output: Columns = undefined;
    var first: usize = 0;

    while (first < imports.len) {
        const count = @min(batch_size, imports.len - first);

        output.fill(.{
            .source = header.source,
            .intrinsic = project.intrinsic_import,
            .packages = &.{ .items = @ptrCast(&names), .length = names.count },
            .imports = imports,
            .first = first,
            .count = count,
            .routes = undefined,
            .matches = undefined,
            .duplicates = undefined,
        });

        for (0..count) |index| {
            const item = header.importAt(first + index);
            const route = output.routes[index];

            const selected: ?project.PackageMatch = if (route == .Package) .{
                .first = if (output.matches[index] == 0) null else @intCast(output.matches[index] - 1),
                .duplicate = output.duplicates[index] != 0,
            } else null;

            try collector.importPlanned(item.path, position.deferred(item.span.start), .dependency, route, selected);
        }

        first += count;
    }
}

const Columns = struct {
    routes: [batch_size]project.ImportRoute,
    matches: [batch_size]u64,
    duplicates: [batch_size]u8,
    fn fill(self: *Columns, request: Input) void {
        var input = request;
        const routes: []project.ImportRoute = &self.routes;
        const matches: []u64 = &self.matches;
        const duplicates: []u8 = &self.duplicates;
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        input.routes = @ptrCast(&routes);
        input.matches = @ptrCast(&matches);
        input.duplicates = @ptrCast(&duplicates);

        zx.columns.invoke(plan.executeValue, empty.allocator(), @as(*const Input, &input)) catch unreachable;
    }
};
