const std = @import("std");
pub const entry = @import("generated_rx_execute_constraints");
pub const Input = std.meta.Child(entry.Input);
pub const Ports = std.meta.Child(@FieldType(Input, "ports"));
pub const Collection = std.meta.Child(@FieldType(Input, "collection"));
pub const Solve = std.meta.Child(@FieldType(Input, "solve"));
pub const Signatures = std.meta.Child(@FieldType(Input, "signatures"));

pub fn slot(comptime marker: []const u8) []const u8 {
    inline for (@typeInfo(entry.zx_pending).@"struct".field_names) |name| {
        if (@hasField(std.meta.Child(Store(name)), marker)) return name;
    }

    @compileError("Missing constraint store field: " ++ marker);
}

pub fn Store(comptime name: []const u8) type {
    return std.meta.Child(@FieldType(entry.zx_pending, name));
}
