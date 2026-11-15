const Collector = @import("collect.zig");
const position = @import("position.zig");

pub fn collect(collector: *Collector, header: anytype) Collector.Error!void {
    for (0..header.importCount()) |index| {
        const item = header.importAt(index);

        try collector.import(item.path, position.deferred(item.span.start), .dependency, null);
    }
}
