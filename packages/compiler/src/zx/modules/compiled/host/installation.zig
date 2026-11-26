const std = @import("std");
const zx = @import("zx");
const model = @import("../../compiled.zig");
const load = @import("../load.zig");
const Input = @import("input.zig");
const function = @import("function.zig");
const interface = @import("interface.zig");
const native = @import("../../link/native/host.zig");
const TypeView = @import("../../../analysis/semantic/merging/publication/view.zig");
const Origins = @import("../../nominal_origins.zig");
const Request = std.meta.Child(@import("generated_compiled_library").Input);
pub const Layout = std.meta.Child(@FieldType(Request, "installation"));
const Self = @This();

functions: function.View,
offsets: TypeView.Offsets,
options: TypeView.Options,
types: TypeView,
natives: native.View,
public: interface.View,
owner: std.mem.Allocator,
first: usize,
needs_interface: bool,
reserve: std.meta.Child(@FieldType(Layout, "reserve")),
commit: std.meta.Child(@FieldType(Layout, "commit")),
input: Layout,
pub fn init(self: *Self, allocator: *const std.mem.Allocator, input: *const Input, library: *const model.Library, destination: load.Destination, call_scratch: ?load.CallScratch, initializer_tail: ?[]model.StoreInitializer) void {
    self.owner = if (call_scratch) |scratch| scratch.functions else allocator.*;
    self.first = destination.functions.count();
    self.needs_interface = call_scratch == null;

    const source = library.program.functions;

    self.functions.init(destination.functions, source, self.first, library.instance);

    self.offsets = TypeView.offsets(destination.types);

    self.options = .{
        .allocator = allocator.*,
        .payload = allocator.*,
        .types = destination.types,
        .origins = &destination.origins.items,
        .offsets = &self.offsets,
    };

    self.types.init(&self.options, .{}, @as(Origins.Table, .{}));
    self.natives.init(allocator, destination.native_modules, .{}, &.{}, null);

    if (self.needs_interface) self.public.init(input, library.instance, self.first, initializer_tail);

    self.reserve = .{ .storage = self.functions.target.storage, .resource = @ptrCast(&self.owner), .shape = null, .count = source.count() };
    self.commit = .{ .lengths = @ptrCast(&self.functions.lengths), .progress = self.functions.input.progress };

    const types: *const TypeView.Target = &self.types.target;
    const natives: *const @TypeOf(self.natives.destination) = &self.natives.destination;

    self.input = .{
        .types = zx.columns.pointer(@FieldType(Layout, "types"), types),
        .natives = zx.columns.pointer(@FieldType(Layout, "natives"), natives),
        .reserve = &self.reserve,
        .functions = &self.functions.input,
        .interface = if (self.needs_interface) &self.public.request else null,
        .commit = &self.commit,
    };
}

pub fn result(self: *const Self, destination: load.Destination, count: usize) model.Loaded {
    std.debug.assert(destination.functions.count() - self.first == count);

    const exports = if (self.needs_interface) self.public.result() else interface.Interface{};

    return .{ .types = destination.types.view(), .nominal_types = destination.origins.items.view(), .exports = exports.exports, .store_initializers = exports.initializers };
}
