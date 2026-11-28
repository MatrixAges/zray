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
    bound: bool = false,
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
        self.view = .{ .object = &self.object, .parents = self.graph.parents(), .known = &self.known, .site = &self.access.site };
        self.bound = true;
    }
};

pub fn apply(frame: *Frame, effect: anytype, reply: anytype) zx.Error!void {
    switch (effect.object_step) {
        .RefreshFields => refresh(frame),
        .ExpectField => try frame.graph.expect(@fromBackingInt(effect.source.?), @fromBackingInt(effect.target.?), frame.span),
        .RegisterFields => try @import("../known.zig").registerMembers(frame.graph, effect.members.?, frame.span),
        .UnifyFields => try frame.graph.unify(@fromBackingInt(effect.target.?), @fromBackingInt(effect.source.?), frame.span),
        .RejectField => return frame.graph.reporter.fail(if (effect.name_error.?) .name else .type_mismatch, frame.span, effect.message.?),
        else => try Access.apply(&frame.access, effect, reply),
    }
}

fn refresh(frame: *Frame) void {
    const was_bound = frame.bound;
    const previous_kind = if (was_bound) frame.access.receiver.kind else undefined;
    const previous_count = if (was_bound) frame.access.members.values.len else 0;

    frame.bind();

    if (was_bound and (frame.access.receiver.kind != previous_kind or frame.access.members.values.len != previous_count)) {
        frame.graph.revision += 1;
    }
}
