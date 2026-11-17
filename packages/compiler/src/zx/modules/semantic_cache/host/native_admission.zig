const std = @import("std");
const zx = @import("zx");
const FunctionImport = @import("../../function_import.zig");
const Request = @import("native_input.zig").Request;
const rule = @import("generated_native_cache_admission");
const Input = std.meta.Child(rule.Input);
const Bindings = std.meta.Child(@FieldType(Input, "imports"));
const Ports = std.meta.Child(@FieldType(Bindings, "ports"));
const Error = std.mem.Allocator.Error || error{InvalidModule};

pub fn check(allocator: std.mem.Allocator, request: *const Request, imports: []const FunctionImport) Error!void {
    const readable = FunctionImport.Readable.borrowRows(imports);
    const names = zx.memory.borrowTextColumn("name", imports);
    const namespaces = zx.memory.borrowReadColumn(?[]const u8, "namespace", imports);

    const input: Input = .{
        .request = zx.columns.pointer(@FieldType(Input, "request"), request),
        .imports = &.{
            .ports = &readable.view(Ports),
            .names = @ptrCast(&names),
            .namespaces = @ptrCast(&namespaces),
        },
    };

    const valid = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    if (!valid) return error.InvalidModule;
}
