const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const view = @import("../../node/view.zig");
const generated = @import("generated_state_list");
const Call = std.meta.Child(generated.Input);
const Query = std.meta.Child(@FieldType(Call, "request"));
const Operation = @FieldType(Query, "operation");
pub const Ast = std.meta.Child(@FieldType(Query, "ast"));
const Storage = @FieldType(Call, "storage");
const publication = @import("../construction/publication.zig");

const Request = struct {
    value: node.ExpressionId = @fromBackingInt(0),
    condition: node.ExpressionId = @fromBackingInt(0),
    unique: node.ExpressionId = @fromBackingInt(0),
    storage: Storage = .Plain,
    selected: bool = false,
    flag: bool = false,
};

pub fn lower(self: *Lower, id: ?ir.TypeId, operation: Operation, request: Request) Lower.Error!node.ExpressionId {
    const ast = borrow(self);

    const query: Query = .{
        .operation = operation,
        .selected = request.selected,
        .value = @backingInt(request.value),
        .ast = &ast,
    };

    const call: Call = .{
        .lower = @ptrCast(self),
        .writer = @ptrCast(self),
        .type_id = if (id) |type_id| @backingInt(type_id) else 0,
        .request = &query,
        .condition = @backingInt(request.condition),
        .unique = @backingInt(request.unique),
        .storage = request.storage,
        .flag = request.flag,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    return @fromBackingInt(generated.executeIn(buffered.allocator(), &call) catch |err| return publication.failure(err));
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
