const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const Store = @import("../../store.zig");
const Layout = @import("../layout.zig");
const Types = @import("../type.zig");
const Error = std.mem.Allocator.Error || error{InvalidSource};
const generated = @import("rx_options").generated_graph;

pub const Frame = struct {
    allocator: std.mem.Allocator,
    temporary: std.mem.Allocator,
    backing: std.mem.Allocator,
    options: *const Store.Options,
    path: []const u8,
    name: []const u8,
    version: u32,
    groups: ?rx.store.Groups,
    value_imports: ?frontend.expressions.BindingColumns,
    layout: Layout = undefined,
    types: zx.ir.TypeStorage = undefined,
    field_types: []const zx.ir.TypeId = undefined,
    values: frontend.expressions.BindingColumns = undefined,
    natives: zx.ir.NativeModuleTable = undefined,
    objects: []Store.Object = undefined,
    complete: zx.ir.TypeTable = undefined,
    result: Store.Value = undefined,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
    fn diagnostic(self: *Frame, issue: @import("../../expression.zig").Diagnostic) Error {
        self.result = try Store.failure(self.allocator, self.path, issue.location, @tagName(issue.issue.code), issue.issue.message);

        return error.InvalidSource;
    }
};

pub fn run(frame: *Frame) std.mem.Allocator.Error!Store.Value {
    if (comptime generated) {
        const rule = @import("generated_rx_prepare_store_definition");
        const Input = std.meta.Child(rule.Input);
        const Shared = std.meta.Child(@FieldType(Input, "shared"));
        const options = frame.options;
        const table = zx.ir.TypeTable.borrow(std.meta.Child(@FieldType(Shared, "table")), options.types);
        const origins = @TypeOf(options.nominal_types).borrow(std.meta.Child(@FieldType(Shared, "origins")), options.nominal_types);
        const aliases = zx.memory.borrowNamedRows("type_id", options.aliases);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        rule.executeIn(empty.allocator(), &.{
            .state = @ptrCast(frame),
            .shared = &.{
                .table = &table,
                .modules = zx.columns.pointer(@FieldType(Shared, "modules"), &options.native_modules),
                .origins = &origins,
                .names = options.nominal_types.names,
                .scalar_count = std.enums.values(zx.ir.Scalar).len,
                .maximum_count = std.math.maxInt(u32),
            },
            .aliases = &.{ .aliases = @ptrCast(&aliases), .length = aliases.len, .type_count = options.types.count() },
        }) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSource => return frame.result,
            else => unreachable,
        };
    } else seed(frame) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSource => return frame.result,
    };

    return frame.result;
}

pub fn collectStoreDefinitionLayout(handle: *anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);

    frame.layout = try Layout.build(frame.temporary, frame.options.node, frame.groups);
}

pub fn rejectStoreDefinitionContext(handle: *anyopaque, message: []const u8) Error!void {
    const frame = Frame.borrow(handle);

    return frame.diagnostic(try Types.contextDiagnostic(frame.temporary, frame.layout, message));
}

pub fn resolveStoreDefinitionTypes(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const result = try Types.resolve(frame.allocator, frame.temporary, frame.path, frame.layout, frame.options.types, frame.options.aliases);

    if (result == .diagnostic) return frame.diagnostic(result.diagnostic);

    frame.types = result.resolved.types;
    frame.field_types = result.resolved.fields;
}

pub fn reserveStoreDefinitionObjects(handle: *anyopaque) std.mem.Allocator.Error!u64 {
    const frame = Frame.borrow(handle);

    frame.values = frame.value_imports orelse try @import("../../project/type_imports.zig").values(frame.temporary, frame.types.view(), frame.options.aliases);
    frame.natives = try frontend.native_context.copy(frame.allocator, frame.options.native_modules);
    frame.objects = try frame.allocator.alloc(Store.Object, frame.layout.starts.len);

    return frame.objects.len;
}

pub fn compileStoreDefinitionObject(handle: *anyopaque, row: u64) Error!void {
    const frame = Frame.borrow(handle);
    const first = frame.layout.starts[@intCast(row)];

    const initialized = try @import("../initializer.zig").compile(frame.allocator, frame.backing, .{
        .owner = frame.path,
        .layout = frame.layout,
        .first = first,
        .field_types = frame.field_types,
        .types = &frame.types,
        .native_modules = frame.natives,
        .aliases = frame.values,
    });

    if (initialized == .diagnostic) return frame.diagnostic(initialized.diagnostic);

    const name = @import("../../call/target.zig").attribute(frame.layout.fragments[first], "name").value;

    frame.objects[@intCast(row)] = .{
        .name = try frame.allocator.dupe(u8, name),
        .identity = try @import("../names.zig").qualify(frame.allocator, frame.path, name, .identity),
        .initial = initialized.program,
    };
}

pub fn freezeStoreDefinitionTypes(handle: *anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.complete = frame.types.view();
}

pub fn publishStoreDefinition(handle: *anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);

    for (frame.objects) |*object| {
        object.initial.types = frame.complete;
    }

    frame.result = .{ .definition = .{
        .source_path = frame.path,
        .name = try frame.allocator.dupe(u8, frame.name),
        .version = frame.version,
        .types = frame.complete,
        .objects = frame.objects,
    } };
}

fn seed(frame: *Frame) Error!void {
    const options = frame.options;
    const types = options.types;

    try collectStoreDefinitionLayout(frame);

    if (types.count() != 0 and !frontend.validateTypes(types)) return rejectStoreDefinitionContext(frame, "invalid shared Store type table");
    if (!frontend.native_context.valid(types, options.native_modules)) return rejectStoreDefinitionContext(frame, "invalid shared native module table");
    if (!try frontend.validateNominalTypes(types, options.nominal_types)) return rejectStoreDefinitionContext(frame, "invalid shared nominal type table");

    for (options.aliases) |alias| {
        if (@backingInt(alias.type_id) >= types.count()) return rejectStoreDefinitionContext(frame, "Store type alias is missing from the shared type table");
    }

    try resolveStoreDefinitionTypes(frame);

    const count = try reserveStoreDefinitionObjects(frame);

    for (0..count) |row| try compileStoreDefinitionObject(frame, row);

    frame.complete = frame.types.view();

    for (frame.objects) |*object| object.initial.types = frame.complete;
    try publishStoreDefinition(frame);
}
