const frontend = @import("frontend");
const zx = @import("zx");
const position = @import("position.zig");
const Collector = @import("collect.zig");
const enabled = @import("rx_options").generated_graph;

pub fn collect(collector: anytype, parsed: *const frontend.project.ParseCache.ModuleResult) @TypeOf(collector.*).Error!void {
    switch (parsed.*) {
        .native => |*native| try collectSeed(collector, zx.syntax.header.Native{ .program = native.value.parsed.ast }),
        .indexed => |*indexed| if (frontend.project.ParseCache.indexed_enabled) {
            if (comptime enabled) return @import("references/scan.zig").collectZx(collector, indexed.header());
            try collectSeed(collector, indexed.header());
        } else unreachable,
    }
}

fn collectSeed(collector: anytype, header: anytype) @TypeOf(collector.*).Error!void {
    for (0..header.importCount()) |index| {
        const item = header.importAt(index);

        try collector.import(item.path, position.imported(item.span.start, @TypeOf(collector) != *Collector), .dependency, null);
    }
}
