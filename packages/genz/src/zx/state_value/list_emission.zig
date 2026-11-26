const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const view = @import("../../node/view.zig");
const generated = @import("generated_state_list");
const Call = std.meta.Child(generated.Input);
const Input = std.meta.Child(@FieldType(Call, "list"));
const Query = std.meta.Child(@FieldType(Input, "request"));
const Operation = @FieldType(Query, "operation");
pub const Ast = std.meta.Child(@FieldType(Query, "ast"));
const runner = @import("generated_run_state_list");
const publication = @import("../construction/publication.zig");

const Request = struct {
    value: node.ExpressionId = @fromBackingInt(0),
    condition: node.ExpressionId = @fromBackingInt(0),
    unique: node.ExpressionId = @fromBackingInt(0),
    storage: @FieldType(Input, "storage") = .Plain,
    selected: bool = false,
    flag: bool = false,
};

const Frame = struct {
    lower: *Lower,
    query: *const Query,
    request: Request,
    fn borrowHandle(handle: *const anyopaque) *const Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn lower(self: *Lower, id: ?ir.TypeId, operation: Operation, request: Request) Lower.Error!node.ExpressionId {
    const ast = borrow(self);

    const query: Query = .{
        .operation = operation,
        .selected = request.selected,
        .value = @backingInt(request.value),
        .ast = &ast,
    };

    const frame: Frame = .{ .lower = self, .query = &query, .request = request };

    const input: std.meta.Child(runner.Input) = .{
        .frame = @ptrCast(&frame),
        .lower = @ptrCast(self),
        .type_id = if (id) |type_id| @backingInt(type_id) else 0,
        .request = @import("zx").columns.pointer(@FieldType(std.meta.Child(runner.Input), "request"), &query),
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return @fromBackingInt(runner.executeIn(fixed.allocator(), &input) catch |err| return publication.failure(err));
}

pub fn emitListRepresentation(handle: *const anyopaque, layout: ?u32) Lower.Error!u32 {
    const frame = Frame.borrowHandle(handle);
    const self = frame.lower;
    const request = frame.request;
    var query = frame.query.*;
    var ast: Ast = undefined;

    if (layout != null) {
        ast = borrow(self);
        query.ast = &ast;
    }

    const input: Input = .{
        .request = &query,
        .construct = layout != null,
        .condition = @backingInt(request.condition),
        .unique = @backingInt(request.unique),
        .storage = request.storage,
        .flag = request.flag,
        .layout = layout orelse 0,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const call: Call = .{
        .writer = @ptrCast(self),
        .list = &input,
    };

    return generated.executeIn(buffered.allocator(), &call) catch |err| return publication.failure(err);
}

pub fn borrow(self: *const Lower) Ast {
    const rows = &self.builder.nodes.expressions;
    const object = &rows.payloads.object.fields.fields.fields;
    const fields = &self.builder.nodes.field_columns.fields;

    return .{
        .tags = view.slice(@FieldType(Ast, "tags"), rows.tags.items),
        .offsets = rows.offsets.items,
        .boolean = rows.payloads.boolean.values.items,
        .object_start = object.start.values.items,
        .object_count = object.len.values.items,
        .field_name = view.slice(@FieldType(Ast, "field_name"), fields.name.values.items),
        .field_value = view.slice(@FieldType(Ast, "field_value"), fields.value.values.items),
    };
}

pub fn tag(self: *Lower, storage: @import("list_seed.zig").Storage) Lower.Error!node.ExpressionId {
    return lower(self, null, .Tag, .{ .storage = @fromBackingInt(@backingInt(storage)) });
}

pub fn headered(self: *Lower, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    return lower(self, null, .Headered, .{ .value = value });
}

pub fn exclusive(self: *Lower, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    return lower(self, null, .Exclusive, .{ .value = value });
}

pub fn writable(self: *Lower, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    return lower(self, null, .Writable, .{ .value = value });
}

pub fn weakened(self: *Lower, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    return lower(self, null, .Weakened, .{ .value = value });
}

pub fn create(self: *Lower, id: ir.TypeId, slice: node.ExpressionId, has_header: node.ExpressionId) Lower.Error!node.ExpressionId {
    return lower(self, id, .Create, .{ .value = slice, .condition = has_header });
}

pub fn proven(self: *Lower, id: ir.TypeId, slice: node.ExpressionId, has_header: node.ExpressionId, is_unique: node.ExpressionId) Lower.Error!node.ExpressionId {
    return lower(self, id, .Proven, .{ .value = slice, .condition = has_header, .unique = is_unique });
}

pub fn owned(self: *Lower, id: ir.TypeId, slice: node.ExpressionId, has_header: node.ExpressionId) Lower.Error!node.ExpressionId {
    return lower(self, id, .Owned, .{ .value = slice, .condition = has_header, .selected = @import("list.zig").selected(self, id) });
}

pub fn borrowed(self: *Lower, id: ir.TypeId, slice: node.ExpressionId) Lower.Error!node.ExpressionId {
    return lower(self, id, .Borrowed, .{ .value = slice });
}

pub fn items(self: *Lower, id: ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    return lower(self, id, .Items, .{ .value = value, .selected = @import("list.zig").selected(self, id) });
}

pub fn wrap(self: *Lower, id: ir.TypeId, value: node.ExpressionId, has_header: bool) Lower.Error!node.ExpressionId {
    return lower(self, id, .Wrap, .{ .value = value, .flag = has_header, .selected = @import("list.zig").selected(self, id) });
}
