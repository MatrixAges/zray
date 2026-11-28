const Lower = @import("../../lower.zig");
const Frame = @import("frame.zig");
const emission = @import("../emitting.zig");
const Error = Lower.Error;

pub fn emitModuleStandard(frame: *Frame) Error!void {
    const self = frame.lowering;

    if (frame.function == null) return emission.standard(self, &frame.output);

    const std_import = try self.builtin(.import, &.{try self.builder.string("std")});

    try frame.output.append(self.allocator, .{ .constant = .{ .name = "std", .value = std_import } });
}

pub fn emitModuleImports(frame: *Frame) Error!void {
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

pub fn emitModuleTypes(frame: *Frame) Error!void {
    return @import("../../types.zig").lower(frame.lowering, &frame.output, false);
}

pub fn emitModuleExports(frame: *Frame) Error!void {
    return emission.exports(frame.lowering, &frame.output);
}

pub fn emitModuleConstants(frame: *Frame) Error!void {
    return @import("../constants.zig").append(frame.lowering, &frame.output);
}

pub fn emitModuleShape(frame: *Frame) Error!void {
    return @import("../../shape.zig").lower(frame.lowering, &frame.output);
}

pub fn emitModuleAliases(frame: *Frame) Error!void {
    return emission.contracts(frame.lowering, &frame.output);
}

pub fn emitModuleStore(frame: *Frame) Error!void {
    return @import("../../store.zig").declaration(frame.lowering, &frame.output);
}

pub fn emitModuleEntry(frame: *Frame) Error!void {
    return @import("../../entry.zig").declarations(frame.lowering, &frame.output);
}

pub fn emitModuleValueEntry(frame: *Frame) Error!void {
    return @import("../../entry_values.zig").declarations(frame.lowering, &frame.output);
}

pub fn emitModuleParallelAllocator(frame: *Frame) Error!void {
    const output = if (frame.function == null) &frame.suffix else &frame.output;

    return @import("../../parallel/allocator.zig").append(frame.lowering, output);
}

pub fn emitModuleComparison(frame: *Frame, index: u64) Error!void {
    const self = frame.lowering;
    const type_id = frame.comparisons.items[@intCast(index)];

    try frame.suffix.append(self.allocator, try @import("../../comparison.zig").ordering(self, type_id));
}

pub fn suffixSeed(frame: *Frame) Error!void {
    if (frame.lowering.uses_parallel) try emitModuleParallelAllocator(frame);
    for (0..frame.comparisons.items.len) |index| try emitModuleComparison(frame, index);
}
