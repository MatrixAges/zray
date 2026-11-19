//! The value functions generated code still calls through their pointer-ABI `call`. A value function's file holds
//! only its value variant unless a caller lowers a call to it the pointer way, which lowering decides per call site;
//! the decision is read back from the generated sources, where each such call reads `@import("<module>")).call(`.
const std = @import("std");
const generating = @import("genz").zx.modules;
const Batch = @import("batch.zig");
const function_sources = @import("function_sources.zig");
const search = @import("search.zig");
const needle = "\")).call(";

/// Gives `call` to every value function in `units` that `roots` or the files reach through it, regenerating those
/// files until every `call` they reach exists; `sources` are the files of `units` and are updated in place.
pub fn complete(owned: std.mem.Allocator, batch: *const Batch, roots: []const []const u8, units: []generating.FunctionUnit, sources: [][]const u8) generating.Error!void {
    var scratch = std.heap.ArenaAllocator.init(batch.backing);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const values = batch.analysis.value.value.values;
    const wanted = try temporary.alloc(bool, values.len);
    var modules: @import("zx").bytes.Map(u32) = .empty;

    @memset(wanted, false);

    for (units) |unit| if (!unit.regular and values[@backingInt(unit.id)]) {
        try modules.put(temporary, batch.names.functions[@backingInt(unit.id)], @backingInt(unit.id));
    };

    if (modules.count() == 0) return;

    var scanned = try std.mem.concat(temporary, []const u8, &.{ roots, sources });

    while (true) {
        var scan = Scan{ .sources = scanned, .modules = &modules, .wanted = wanted };

        try function_sources.spread(Scan, &scan, try arenas(temporary, scanned.len));

        var positions: std.ArrayList(u64) = .empty;

        for (units, 0..) |*unit, position| if (!unit.regular and values[@backingInt(unit.id)]) {
            const id = unit.id;
            const representative = modules.get(batch.names.functions[@backingInt(id)]).?;

            if (!wanted[representative]) continue;

            unit.regular = true;

            try positions.append(temporary, position);
        };

        if (positions.items.len == 0) return;

        const regenerated = try function_sources.createJobs(owned, .{ .batch = batch, .functions = units, .positions = positions.items });

        for (positions.items, regenerated) |position, source| sources[position] = source;

        scanned = regenerated;
    }
}

/// Marks the value functions each source calls through `call`, on all cores.
const Scan = struct {
    sources: []const []const u8,
    modules: *const @import("zx").bytes.Map(u32),
    wanted: []bool,
    next: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(u16) = .init(0),
    pub fn run(self: *Scan, _: *std.heap.ArenaAllocator) void {
        while (true) {
            const position = self.next.fetchAdd(1, .monotonic);

            if (position >= self.sources.len) return;

            const source = self.sources[position];
            var cursor: usize = 0;

            while (search.find(source, cursor, needle)) |at| {
                cursor = at + needle.len;

                const open = std.mem.lastIndexOfScalar(u8, source[0..at], '"') orelse continue;
                const index = self.modules.get(source[open + 1 .. at]) orelse continue;

                @atomicStore(bool, &self.wanted[index], true, .monotonic);
            }
        }
    }
};

fn arenas(temporary: std.mem.Allocator, count: usize) std.mem.Allocator.Error![]std.heap.ArenaAllocator {
    const result = try temporary.alloc(std.heap.ArenaAllocator, @min(@import("zx").parallel.width(), count));

    for (result) |*arena| arena.* = .init(temporary);

    return result;
}
