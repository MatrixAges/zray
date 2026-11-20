const std = @import("std");
pub const entry = @import("generated_artifact_binding_batch");
pub const Input = std.meta.Child(entry.Input);
pub const Row = std.meta.Elem(@FieldType(Input, "rows"));
pub const Binding = std.meta.Child(@FieldType(std.meta.Child(Row), "binding"));
pub const Output = std.meta.Child(entry.Output);
pub const Retained = @typeInfo(@FieldType(Output, "entry")).optional.child;
