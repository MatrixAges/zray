const std = @import("std");
const ir = @import("zx").ir;
const Signature = @import("../../source_signature.zig");
const FunctionImport = @import("../../function_import.zig");
const Members = @import("../members.zig");
const rule = @import("generated_project_binding_delivery");
const Input = std.meta.Child(rule.Input);
const Rows = std.meta.Child(@typeInfo(@FieldType(Input, "reexports")).optional.child);
const Facts = std.meta.Child(@FieldType(Rows, "facts"));
const Source = std.meta.Child(@FieldType(Facts, "members"));
const Named = std.meta.Child(@FieldType(Source, "named"));
const Fallback = std.meta.Child(@typeInfo(@FieldType(Source, "fallback")).optional.child);
const Kinds = std.meta.Child(@FieldType(Rows, "kinds"));

const Tail = @import("tail.zig").Tail(Signature.Member, Rows, .{
    .input_type = &.{ "ports", "input_type" },
    .output_type = &.{ "ports", "output_type" },
});

const kinds = Signature.kinds(Kinds);
const Self = @This();

pub const List = struct {
    signatures: []const Signature.Member,
    bindings: Members,
    stores: []const *const ir.StoreTable,
    rows: *std.ArrayList(Signature.Member),
    backing: std.mem.Allocator,
};

tail: Tail,
member_ports: FunctionImport.Readable,
named: Named,
fallback: Fallback,
source: Source,
facts: Facts,
backing: std.mem.Allocator,
input: Rows,
pub fn init(self: *Self, list: List) void {
    self.tail.init(list.rows);

    self.member_ports = FunctionImport.Readable.borrowRows(list.bindings.named);
    self.named = self.member_ports.view(Named);

    if (list.bindings.default) |member| self.fallback = member.borrow(Fallback);

    self.source = .{
        .named = &self.named,
        .fallback = if (list.bindings.default != null) &self.fallback else null,
    };

    self.facts = Signature.bindingFacts(Facts, &self.source, list.stores);
    self.backing = list.backing;

    self.input = .{
        .target = &self.tail.output.view,
        .storage = @ptrCast(&self.tail.output.buffer),
        .used = @ptrCast(&self.tail.used),
        .buffer = @ptrCast(&self.tail.output.buffer.bytes),
        .signatures = std.mem.sliceAsBytes(list.signatures),
        .stride = @sizeOf(Signature.Member),
        .facts = &self.facts,
        .kinds = &kinds,
        .backing = @ptrCast(&self.backing),
    };
}

pub fn commit(self: *Self) void {
    self.tail.commit();
}
