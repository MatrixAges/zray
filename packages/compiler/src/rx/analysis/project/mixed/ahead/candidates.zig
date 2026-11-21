const std = @import("std");
const Body = @import("../body.zig");
const Self = @This();
pub const generated = @import("rx_options").generated_graph and @bitSizeOf(usize) == 64 and @alignOf(usize) >= @alignOf(u64);
pub const chunk_size = 8;
pub const Item = struct { position: usize, action: Body.Action };

state: *const @import("../state.zig"),
reuse: *const @import("../reuse.zig"),
local_calls: []const bool,
position: usize,
end: usize,

positions: [chunk_size]u64 = undefined,
first: usize = 0,
count: usize = 0,
pub fn next(self: *Self) ?Item {
    const graph = &self.state.graph;

    while (true) {
        if (self.first == self.count) {
            if (self.position == self.end) return null;

            self.fillSeed();

            if (self.count == 0) return null;
        }

        const row = self.first;
        const position: usize = @intCast(self.positions[row]);
        const index = graph.order[position];

        self.first += 1;

        if (!self.reuse.reusable(self.state, index, position)) {
            return .{ .position = position, .action = if (index < graph.sources.zx_count) .AnalyzeZX else .LowerRX };
        }
    }
}

fn fillSeed(self: *Self) void {
    const graph = &self.state.graph;
    self.first = 0;
    self.count = 0;

    while (self.position < self.end and self.count < self.positions.len) : (self.position += 1) {
        const index = graph.order[self.position];

        if (graph.modules.items(.compiled_dependency)[index]) continue;

        switch (graph.sources.at(index)) {
            .zx => |row| if (self.state.signature_indices[row] <= 0) continue,
            .rx => |row| if (index == graph.entry or !self.local_calls[row]) continue,
            .store => continue,
        }

        self.positions[self.count] = self.position;
        self.count += 1;
    }
}
