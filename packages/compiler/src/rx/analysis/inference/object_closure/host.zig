const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Kind = @import("../nodes.zig").Kind;
const Closure = @import("../object_closure.zig");
const rule = @import("generated_rx_prove_object_readiness");
const Input = std.meta.Child(rule.Input);
pub const Context = std.meta.Child(@FieldType(Input, "context"));
const Cache = std.meta.Child(@FieldType(Context, "cache"));
const Query = std.meta.Child(@FieldType(Input, "query"));
pub const Snapshot = std.meta.Child(std.meta.Child(@FieldType(Cache, "snapshot")));

pub const Session = struct {
    closure: *Closure,
    graph: *const Graph,
    cache: Cache = undefined,
    pub fn bind(self: *Session) void {
        self.cache.snapshot = if (self.closure.snapshot) |*data| &data.query else null;
    }
    pub fn context(self: *Session) Context {
        return .{ .frame = @ptrCast(self), .cache = &self.cache };
    }

    fn borrow(handle: *const anyopaque) *Session {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn prove(closure: *Closure, graph: *const Graph, root: Graph.Id, kind: Kind, constructions: usize, selections: usize, spread: bool) std.mem.Allocator.Error!bool {
    var session: Session = .{ .closure = closure, .graph = graph };

    session.bind();

    const input: Input = .{
        .context = &session.context(),
        .query = &.{
            .root = @backingInt(root),
            .kind = zx.columns.view(@FieldType(Query, "kind"), kind),
            .revision = graph.object_revision,
            .constructions = constructions,
            .selections = selections,
            .spread = spread,
        },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return rule.executeIn(empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

pub fn rebuildObjectReadiness(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const session = Session.borrow(handle);

    try session.closure.rebuild(session.graph);

    session.bind();
}

pub fn propagateObjectReadiness(handle: *const anyopaque, position: u64, spread: bool, shared: bool) std.mem.Allocator.Error!bool {
    const session = Session.borrow(handle);

    return session.closure.propagate(session.graph.pending.constructions.len, position, spread, shared);
}
