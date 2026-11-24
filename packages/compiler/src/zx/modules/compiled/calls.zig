const std = @import("std");
const ir = @import("zx").ir;
const model = @import("../compiled.zig");
const Context = @import("../../analysis/analyze.zig").Context;
const Origins = @import("../nominal_origins.zig");
const load = @import("load.zig");
const generated = @import("parser_options").generated_parser;
const Self = @This();

types: ir.TypeStorage,
origins: Origins,
natives: ir.NativeModuleStorage,

checked: bool = false,
pub fn init(allocator: std.mem.Allocator, context: *const Context) !Self {
    const types = try @import("../../analysis/type_table.zig").storage(allocator, context.types);

    var origins: Origins = if (comptime generated)
        try Origins.copy(allocator, context.nominal_types)
    else
        .{ .allocator = allocator };

    if (comptime !generated) try origins.seed(types.view(), context.nominal_types);

    return .{ .types = types, .origins = origins, .natives = try @import("../native_context.zig").storage(allocator, context.native_modules) };
}

pub fn link(self: *Self, allocator: std.mem.Allocator, library: model.Library, functions: *ir.FunctionStorage, scratch: load.CallScratch) !void {
    const destination: load.Destination = .{ .types = &self.types, .origins = &self.origins, .functions = functions, .native_modules = &self.natives };

    if (comptime generated) {
        try @import("host/root.zig").loadCalls(allocator, library, destination, scratch, !self.checked);
    } else {
        _ = try load.loadInto(allocator, library, destination);
    }
}

pub fn publish(self: *Self, context: *Context) void {
    context.types = self.types.view();
    context.nominal_types = self.origins.items.view();
    context.native_modules = self.natives.view();
    self.checked = true;
}
