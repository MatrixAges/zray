const std = @import("std");
const ir = @import("zx").ir;
const Loaded = @import("frontend").project.artifact.source_link.Loaded;
const Self = @This();

const Surface = struct {
    input_type: @FieldType(Loaded, "input_type"),
    output_type: @FieldType(Loaded, "output_type"),
    exports: @FieldType(Loaded, "exports"),
    constant_exports: @FieldType(Loaded, "constant_exports"),
    store_initializers: @FieldType(Loaded, "store_initializers"),
    members: @FieldType(Loaded, "members"),
};

const Row = struct { surface: Surface, function: ?u32, present: bool };

surfaces: []Surface = &.{},
functions: []?u32 = &.{},
present: []bool = &.{},
pub fn init(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Self {
    var storage: std.MultiArrayList(Row) = .empty;

    try storage.setCapacity(allocator, count);

    storage.len = count;

    const slice = storage.slice();
    const present = slice.items(.present);

    @memset(present, false);

    return .{ .surfaces = slice.items(.surface), .functions = slice.items(.function), .present = present };
}

pub fn get(self: Self, index: usize) ?Loaded {
    return if (self.present[index]) self.getAssumePresent(index) else null;
}

pub fn getAssumePresent(self: Self, index: usize) Loaded {
    std.debug.assert(self.present[index]);

    const surface = &self.surfaces[index];
    var value: Loaded = undefined;

    value.function = self.function(index);

    inline for (@typeInfo(Surface).@"struct".field_names) |field| @field(value, field) = @field(surface, field);

    return value;
}

pub fn function(self: Self, index: usize) ?ir.FunctionId {
    return if (self.functions[index]) |id| @fromBackingInt(id) else null;
}

pub fn namedFunction(self: Self, index: usize, name: []const u8) ?ir.FunctionId {
    if (!self.present[index]) return null;

    for (self.surfaces[index].members) |*member| {
        if (std.mem.eql(u8, member.name, name)) return member.id;
    }

    return null;
}

pub fn set(self: Self, index: usize, value: Loaded) void {
    const surface = &self.surfaces[index];

    inline for (@typeInfo(Surface).@"struct".field_names) |field| @field(surface, field) = @field(value, field);

    self.functions[index] = if (value.function) |id| @backingInt(id) else null;
    self.present[index] = true;
}

pub fn retain(self: Self, earlier: Self, index: usize) void {
    const present = earlier.present[index];

    if (present) {
        self.surfaces[index] = earlier.surfaces[index];
        self.functions[index] = earlier.functions[index];
    }

    self.present[index] = present;
}
