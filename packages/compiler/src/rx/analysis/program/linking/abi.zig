const std = @import("std");
pub const entry = @import("generated_rx_inline_expression");
pub const Request = std.meta.Child(entry.Input);
pub const Payload = std.meta.Child(@FieldType(Request, "payload"));
pub const Output = @typeInfo(@TypeOf(entry.executeValue(undefined, undefined))).error_union.payload;
