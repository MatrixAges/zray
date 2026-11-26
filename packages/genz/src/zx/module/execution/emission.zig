const Lower = @import("../../lower.zig");
const Frame = @import("frame.zig");
const emission = @import("../emitting.zig");
const Error = Lower.Error;

pub fn standard(frame: *Frame) Error!void {
    const self = frame.lowering;

    if (frame.function == null) return emission.standard(self, &frame.output);

    const std_import = try self.builtin(.import, &.{try self.builder.string("std")});

    try frame.output.append(self.allocator, .{ .constant = .{ .name = "std", .value = std_import } });
}

pub fn imports(frame: *Frame) Error!void {
    const self = frame.lowering;

    const selected = frame.function orelse {
        self.native_names = try @import("../../imports.zig").lower(self, &frame.output);

        return;
    };

    const external = self.program.functions.native_modules[@backingInt(selected)].?;
    const modules = self.program.native_modules;
    const module = modules.at(external);
    const native_names = try self.allocator.alloc([]const u8, modules.count());

    @memset(native_names, "");

    native_names[external] = "zx_native";
    self.native_names = native_names;

    const value = try self.builtin(.import, &.{try self.builder.string(module.import_name)});

    try frame.output.append(self.allocator, .{ .constant = .{ .name = "zx_native", .value = value } });
}

pub fn types(frame: *Frame) Error!void {
    return @import("../../types.zig").lower(frame.lowering, &frame.output, false);
}

pub fn exports(frame: *Frame) Error!void {
    return emission.exports(frame.lowering, &frame.output);
}

pub fn constants(frame: *Frame) Error!void {
    return @import("../constants.zig").append(frame.lowering, &frame.output);
}

pub fn shape(frame: *Frame) Error!void {
    return @import("../../shape.zig").lower(frame.lowering, &frame.output);
}

pub fn aliases(frame: *Frame) Error!void {
    return emission.contracts(frame.lowering, &frame.output);
}

pub fn store(frame: *Frame) Error!void {
    return @import("../../store.zig").declaration(frame.lowering, &frame.output);
}

pub fn entry(frame: *Frame) Error!void {
    return @import("../../entry.zig").declarations(frame.lowering, &frame.output);
}

pub fn valueEntry(frame: *Frame) Error!void {
    return @import("../../entry_values.zig").declarations(frame.lowering, &frame.output);
}

pub fn suffix(frame: *Frame) Error!void {
    const self = frame.lowering;

    if (self.uses_parallel) {
        const output = if (frame.function == null) &frame.suffix else &frame.output;

        try @import("../../parallel/allocator.zig").append(self, output);
    }

    for (frame.comparisons.items) |type_id| {
        try frame.suffix.append(self.allocator, try @import("../../comparison.zig").ordering(self, type_id));
    }
}
