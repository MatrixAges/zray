const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const View = @import("view.zig");
const Access = @import("access.zig");

pub fn borrow(comptime Object: type, graph: *const Graph, root: Graph.Id) Object {
    const fields = View.read(graph, root);

    return .{
        .mode = @fromBackingInt(@backingInt(fields.mode)),
        .restricted = graph.nodes.items(.allowed)[@backingInt(root)] != null,
        .names = fields.names,
        .values = fields.values,
    };
}

fn append(graph: *Graph, root: Graph.Id, name: []const u8, span: zx.Span) zx.Error!Graph.Id {
    const index = @backingInt(root);
    const members = graph.nodes.items(.members)[index];
    const fields = Graph.Fields.fromValues(@ptrCast(members));

    return Access.append(graph, index, fields, name, span);
}

const entry = @import("generated_rx_apply_object_selection");
const Input = std.meta.Child(entry.Input);
const Binding = std.meta.Child(@FieldType(Input, "field_view"));
const FieldView = std.meta.Child(@FieldType(Binding, "object"));
const Known = std.meta.Child(@FieldType(Binding, "known"));

pub const Frame = struct {
    graph: *Graph,
    result: Graph.Id,
    span: zx.Span,
    root: Graph.Id = undefined,
    view: Binding = undefined,
    object: FieldView = undefined,
    known: Known = undefined,
    parents: []u32 = undefined,
    pub fn bind(self: *Frame) void {
        self.root = self.graph.root(self.result);
        self.object = borrow(FieldView, self.graph, self.root);
        self.known = self.graph.pending.known_types.borrow(Known);
        self.parents = self.graph.parents();
        self.view = .{ .object = &self.object, .parents = @ptrCast(&self.parents), .known = &self.known };
    }

    pub fn from(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn readObjectReplayField(handle: *const anyopaque, name: []const u8) zx.Error!u32 {
    const frame = Frame.from(handle);

    return @backingInt(try Access.at(frame.graph, frame.result, frame.root, name, frame.span));
}

pub fn appendObjectReplayField(handle: *const anyopaque, name: []const u8) zx.Error!u32 {
    const frame = Frame.from(handle);

    return @backingInt(try append(frame.graph, frame.root, name, frame.span));
}

pub fn registerObjectReplayType(handle: *const anyopaque, value: u32) zx.Error!u32 {
    const frame = Frame.from(handle);

    return @backingInt(try frame.graph.known(@fromBackingInt(value), frame.span));
}

pub fn refreshObjectReplayFields(handle: *const anyopaque) void {
    Frame.from(handle).bind();
}

pub fn expectObjectReplayField(handle: *const anyopaque, source: u32, target: u32) zx.Error!void {
    const frame = Frame.from(handle);

    try frame.graph.expect(@fromBackingInt(source), @fromBackingInt(target), frame.span);
}

pub fn registerDeclaredFields(handle: *const anyopaque, members: []const u32) zx.Error!void {
    const frame = Frame.from(handle);

    try @import("../known.zig").registerMembers(frame.graph, members, frame.span);
}

pub fn unifyReplayFields(handle: *const anyopaque, target: u32, source: ?u32) zx.Error!void {
    const frame = Frame.from(handle);

    try frame.graph.unify(@fromBackingInt(target), @fromBackingInt(source.?), frame.span);
}

pub fn reportFieldError(handle: *const anyopaque, code: []const u8, message: []const u8) zx.Error!void {
    const frame = Frame.from(handle);
    const tag = std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), code) orelse unreachable;

    return frame.graph.reporter.fail(tag, frame.span, message);
}
