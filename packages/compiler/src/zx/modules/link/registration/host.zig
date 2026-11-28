const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Module = @import("../../artifact/model.zig").Module;
const Types = @import("../types.zig");
const Publication = @import("../../../analysis/semantic/merging/publication/view.zig");
const generated = @import("generated_artifact_type_registration");
const Input = std.meta.Child(generated.Input);
const State = std.meta.Child(@FieldType(generated.zx_pending, "store_0"));
const Base = std.meta.Child(@FieldType(std.meta.Child(State), "base"));
const Source = std.meta.Child(std.meta.Child(@FieldType(Input, "modules")));
const TypeTable = std.meta.Child(@FieldType(Base, "types"));
const Bindings = std.meta.Child(@FieldType(Base, "origins"));

const Host = struct {
    store_0: *State,
    output: *Publication,
    allocator: std.mem.Allocator,
    mappings: [][]const ir.TypeId,
    state: std.meta.Child(State),
    base: Base,
    types: TypeTable,
    origins: Bindings,
    fn refresh(self: *Host) void {
        self.types = ir.TypeTable.borrow(TypeTable, self.output.options.types.view());
        self.origins = @import("nominal_data").Table.borrow(Bindings, self.output.options.origins.?.view());
        self.base = .{ .types = &self.types, .origins = &self.origins };
        self.state = .{ .row = 0, .mapping = &.{}, .publication = null, .base = &self.base };
        self.store_0.* = &self.state;
    }
    pub fn commit(self: *Host, pending: anytype) std.mem.Allocator.Error!void {
        if (pending.store_0) |row| {
            const mapping = try self.allocator.dupe(u32, row.mapping);

            errdefer self.allocator.free(mapping);

            try self.output.commit(row.publication.?);

            self.mappings[row.row] = @ptrCast(mapping);

            self.refresh();
        }
    }
};

const Limits = std.meta.Child(@FieldType(Input, "limits"));

pub fn register(types: *Types, modules: []const Module, order: []const u64, mappings: [][]const ir.TypeId, mapping_allocator: std.mem.Allocator, scratch: *std.heap.ArenaAllocator) Types.Error!void {
    const options: Publication.Options = .{
        .allocator = types.allocator,
        .payload = types.allocator,
        .types = &types.items,
        .origins = &types.origins.items,
    };

    var output: Publication = undefined;

    output.init(options);

    const temporary = scratch.allocator();
    const entries = try temporary.alloc(Source, modules.len);
    const sources = try temporary.alloc(*const Source, modules.len);
    const tables = try temporary.alloc(TypeTable, modules.len);
    const origins = try temporary.alloc(Bindings, modules.len);

    for (modules, entries, sources, tables, origins) |module, *entry, *source, *table, *nominal| {
        table.* = ir.TypeTable.borrow(TypeTable, module.types);
        nominal.* = @import("nominal_data").Table.borrow(Bindings, module.nominal_types);
        entry.* = .{ .types = table, .origins = nominal, .names = module.nominal_types.names };
        source.* = entry;
    }

    const limits: Limits = .{ .maximum_count = std.math.maxInt(u32), .scalar_count = std.enums.values(ir.Scalar).len };
    const publication: Publication.Target = output.target;

    const request: Input = .{
        .order = order,
        .modules = sources,
        .limits = &limits,
        .publication = zx.columns.pointer(@FieldType(Input, "publication"), &publication),
    };

    // The caller releases both owning arenas if a row fails after publishing data.
    var state_ptr: State = undefined;

    var host: Host = .{
        .store_0 = &state_ptr,
        .output = &output,
        .allocator = mapping_allocator,
        .mappings = mappings,
        .state = undefined,
        .base = undefined,
        .types = undefined,
        .origins = undefined,
    };

    host.refresh();

    const status = generated.executeIn(scratch.allocator(), &request, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return switch (status) {
        .Ready => {},
        .MissingOrigin => error.MissingNominalOrigin,
        .Conflict => error.ConflictingNominalType,
        .Invalid => error.InvalidModule,
    };
}
