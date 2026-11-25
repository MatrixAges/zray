const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const View = @import("view.zig");
const Access = @import("host.zig");
const Input = @import("../object_closure/replay.zig").SelectionRow;
const Binding = std.meta.Child(@FieldType(Input, "field_view"));
const FieldView = std.meta.Child(@FieldType(Binding, "object"));
const Known = std.meta.Child(@FieldType(Binding, "known"));

pub const Frame = struct {
    graph: *Graph,
    result: Graph.Id,
    span: zx.Span,
    access: Access.Frame = undefined,
    view: Binding = undefined,
    object: FieldView = undefined,
    known: Known = undefined,
    parents: []u32 = undefined,
    pub fn bind(self: *Frame) void {
        self.access = .{
            .graph = self.graph,
            .target = self.result,
            .root = self.graph.root(self.result),
            .span = self.span,
        };

        const shape = self.access.bind();

        self.object = .{
            .mode = @fromBackingInt(@backingInt(View.classify(shape))),
            .restricted = shape.restricted,
            .names = self.access.members.names,
            .values = self.access.members.values,
        };

        self.known = self.graph.pending.known_types.borrow(Known);
        self.parents = self.graph.parents();
        self.view = .{ .object = &self.object, .parents = @ptrCast(&self.parents), .known = &self.known, .site = &self.access.site };
    }

    pub fn from(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn refreshObjectReplayFields(handle: *anyopaque) void {
    Frame.from(handle).bind();
}

pub fn expectObjectReplayField(handle: *anyopaque, source: u32, target: u32) zx.Error!void {
    const frame = Frame.from(handle);

    try frame.graph.expect(@fromBackingInt(source), @fromBackingInt(target), frame.span);
}

pub fn registerDeclaredReplayFields(handle: *anyopaque, members: []const u32) zx.Error!void {
    const frame = Frame.from(handle);

    try @import("../known.zig").registerMembers(frame.graph, members, frame.span);
}

pub fn unifyReplayFields(handle: *anyopaque, target: u32, source: ?u32) zx.Error!void {
    const frame = Frame.from(handle);

    try frame.graph.unify(@fromBackingInt(target), @fromBackingInt(source.?), frame.span);
}

pub fn reportReplayFieldError(handle: *anyopaque, name_error: bool, message: []const u8) zx.Error!void {
    const frame = Frame.from(handle);

    return frame.graph.reporter.fail(if (name_error) .name else .type_mismatch, frame.span, message);
}
