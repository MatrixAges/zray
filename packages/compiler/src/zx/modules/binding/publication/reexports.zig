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
const kinds = Signature.kinds(Kinds);
const Self = @This();

pub const List = struct {
    signatures: []const Signature.Member,
    bindings: Members,
    stores: []const *const ir.StoreTable,
    rows: *std.ArrayList(Signature.Member),
    backing: std.mem.Allocator,
};

rows: *std.ArrayList(Signature.Member),
signatures: []const Signature.Member,
member_ports: FunctionImport.Readable,
named: Named,
fallback: Fallback,
source: Source,
facts: Facts,
backing: std.mem.Allocator,
owner: std.mem.Allocator,
written: usize,
input: Rows,
pub fn init(self: *Self, list: List, owner: std.mem.Allocator) void {
    self.rows = list.rows;
    self.signatures = list.signatures;
    self.member_ports = FunctionImport.Readable.borrowRows(list.bindings.named);
    self.named = self.member_ports.view(Named);

    if (list.bindings.default) |member| self.fallback = member.borrow(Fallback);

    self.source = .{
        .named = &self.named,
        .fallback = if (list.bindings.default != null) &self.fallback else null,
    };

    self.facts = Signature.bindingFacts(Facts, &self.source, list.stores);
    self.backing = list.backing;
    self.owner = owner;
    self.written = 0;

    self.input = .{
        .used = self.rows.items.len,
        .capacity = self.rows.capacity,
        .base = @max(1, std.atomic.cache_line / @sizeOf(Signature.Member)),
        .signatures = list.signatures.len,
        .facts = &self.facts,
        .kinds = &kinds,
    };
}

pub fn discard(self: *Self) void {
    for (self.rows.unusedCapacitySlice()[0..self.written]) |row| self.owner.free(row.name);
}

pub fn settle(self: *Self, count: u64) void {
    self.rows.items.len = @intCast(count);
}

pub fn commit(self: *Self, pending: anytype) std.mem.Allocator.Error!void {
    if (pending.store_0) |row| {
        if (row.action == .Reserve) {
            return self.rows.ensureTotalCapacityPrecise(self.backing, @intCast(row.row));
        }

        try @import("../../project/exports/signatures/rows.zig").commit(self.owner, self.rows.allocatedSlice(), self.signatures, row);

        self.written += 1;
    }
}
