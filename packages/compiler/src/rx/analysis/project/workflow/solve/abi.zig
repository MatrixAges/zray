const std = @import("std");
pub const entry = @import("generated_rx_execute_constraints");
pub const Input = std.meta.Child(entry.Input);
pub const Ports = std.meta.Child(@FieldType(Input, "ports"));
pub const Collection = std.meta.Child(@FieldType(Input, "collection"));
pub const Solve = std.meta.Child(@FieldType(Input, "solve"));
pub const Signatures = std.meta.Child(@FieldType(Input, "signatures"));
