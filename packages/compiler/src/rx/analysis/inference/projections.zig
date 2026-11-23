const zx = @import("zx");
const Graph = @import("types.zig");

pub const Length = struct { target: Graph.Id, value: Graph.Id, span: zx.Span };
