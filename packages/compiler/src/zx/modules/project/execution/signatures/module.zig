const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const project = @import("../../../project.zig");
const Signature = @import("../../../source_signature.zig");
const FunctionImport = @import("../../../function_import.zig");
const generated = @import("generated_project_signature_publish");
const Input = std.meta.Child(generated.Input);
const Exports = std.meta.Child(@FieldType(Input, "exports"));
const rows = @import("../../exports/publication/rows.zig");
const TypeRows = rows.Rows(zx.ir.Export, std.meta.Child(@FieldType(Exports, "types")), rows.Names);
const ConstantRows = rows.Rows(zx.ir.Constant, std.meta.Child(@FieldType(Exports, "constants")), rows.Names);

const StoreHost = struct {
    allocator: std.mem.Allocator,
    types: *TypeRows,
    constants: *ConstantRows,
    members: *Members,
    pub fn commit(self: *StoreHost, pending: anytype) std.mem.Allocator.Error!void {
        if (pending.store_0) |row| {
            try self.members.commit(self.allocator, row);
        }

        if (pending.store_1) |row| switch (row.kind) {
            .Types => try self.types.merge(self.allocator),
            .Constants => try self.constants.merge(self.allocator),
            .Members => unreachable,
        };
    }
};

const Members = struct {
    const Shape = std.meta.Child(@FieldType(Input, "members"));

    const paths = .{
        .name = &.{"name"},
        .kind = &.{"kind"},
        .input_type = &.{ "ports", "input_type" },
        .output_type = &.{ "ports", "output_type" },
        .source = &.{"source"},
        .has_store = &.{"has_store"},
    };

    const fields = @typeInfo(@TypeOf(paths)).@"struct".field_names;
    const kinds = Signature.kinds(std.meta.Child(@FieldType(Shape, "kinds")));

    storage: []Signature.Member = &.{},
    forwarded: []const Signature.Member,
    columns: [fields.len]memory.ReadColumn = undefined,
    fn column(self: *const Members, comptime name: []const u8) *const memory.ReadColumn {
        return &self.columns[std.meta.fieldIndex(@TypeOf(paths), name).?];
    }

    fn commit(self: *Members, allocator: std.mem.Allocator, row: anytype) std.mem.Allocator.Error!void {
        if (row.action == .Reserve) {
            self.storage = try allocator.alloc(Signature.Member, @intCast(row.row));

            inline for (fields, &self.columns) |name, *descriptor| {
                const path: []const []const u8 = @field(paths, name);
                const Field = memory.columnFieldLayout(Signature.Member, path).type;
                descriptor.* = memory.borrowNestedColumn(Field, path, self.storage);
            }

            return;
        }

        try @import("../../exports/signatures/rows.zig").commit(allocator, self.storage, self.forwarded, row);
    }

    fn request(self: *const Members, signature: *const Signature.Result, bindings: @FieldType(Shape, "bindings"), declaration: @FieldType(Shape, "callable"), facts: @FieldType(Shape, "signature")) Shape {
        return .{
            .callable = declaration,
            .declared = !signature.type_only,
            .kinds = &kinds,
            .forwarded = self.forwarded.len,
            .bindings = bindings,
            .names = @ptrCast(self.column("name")),
            .signature = facts,
        };
    }
};

pub fn run(state: *project.Project, frame: *project.LoadFrame, unit: *project.Unit) zx.Error!void {
    const signature = &unit.signature.?;
    const allocator = state.allocator;
    var members: Members = .{ .forwarded = frame.signature_members.items };
    var types: TypeRows = undefined;
    var constants: ConstantRows = undefined;
    var arena = std.heap.ArenaAllocator.init(state.arena.child_allocator);

    defer arena.deinit();

    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
    const native = frame.export_functions.items;
    const bindings = FunctionImport.Readable.borrowRows(native);
    const BindingShape = std.meta.Child(@FieldType(Members.Shape, "bindings"));
    const Facts = std.meta.Child(@FieldType(BindingShape, "facts"));
    const MemberSource = std.meta.Child(@FieldType(Facts, "members"));
    const empty: []const FunctionImport = &.{};
    const no_ids = memory.borrowOptionalU32Column("id", empty);
    const names = memory.borrowTextColumn("name", native);
    const named = bindings.view(std.meta.Child(@FieldType(MemberSource, "named")));
    const source: MemberSource = .{ .named = &named, .fallback = null };
    const facts = Signature.bindingFacts(Facts, &source, state.functions.stores.items);

    const binding_rows: BindingShape = .{
        .names = @ptrCast(&names),
        .facts = &facts,
        .count = native.len,
    };

    const declaration: std.meta.Child(@FieldType(Members.Shape, "callable")) = .{
        .input_type = @backingInt(signature.ports.input_type),
        .output_type = @backingInt(signature.ports.output_type),
        .has_store = signature.has_store,
    };

    const selection: std.meta.Child(@FieldType(Members.Shape, "signature")) = .{
        .kinds = @ptrCast(members.column("kind")),
        .inputs = @ptrCast(members.column("input_type")),
        .outputs = @ptrCast(members.column("output_type")),
        .stores = @ptrCast(members.column("has_store")),
        .sources = @ptrCast(members.column("source")),
        .callable = @backingInt(Signature.Member.Kind.callable),
        .deferred = @backingInt(Signature.Member.Kind.deferred),
        .intrinsic = @backingInt(Signature.Member.Kind.intrinsic),
    };

    const target = members.request(signature, &binding_rows, &declaration, &selection);
    const type_rows = types.borrow(signature.exports, frame.export_aliases.items, false);
    const constant_rows = constants.borrow(signature.constant_exports, frame.export_constants.items, false);
    const exports: Exports = .{ .types = &type_rows, .constants = &constant_rows };

    errdefer allocator.free(members.storage);
    errdefer allocator.free(types.allocated);
    errdefer allocator.free(constants.allocated);

    const input: Input = .{
        .members = &target,
        .exports = &exports,
        .no_ids = @ptrCast(&no_ids),
    };

    var host: StoreHost = .{
        .allocator = allocator,
        .types = &types,
        .constants = &constants,
        .members = &members,
    };

    const result = generated.executeIn(scratch.allocator(), &input, &host) catch |err| return switch (@as(anyerror, err)) {
        error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @import("../invoke.zig").errorSet(err),
    };

    const effective = result.signature;

    if (effective.duplicate) |name| return project.public_exports.reportDuplicate(allocator, state.reporter, name);
    if (effective.invalid) return state.reporter.fail(.module, .{ .start = 0, .end = 0 }, "a default re-export requires a callable source");

    signature.members = members.storage;
    signature.exports = types.result();
    signature.constant_exports = constants.result();
    signature.ports = .{ .input_type = @fromBackingInt(effective.input_type), .output_type = @fromBackingInt(effective.output_type) };
    signature.has_store = effective.has_store;
    signature.type_only = effective.type_only;
    signature.has_deferred_source = effective.deferred != null;
    signature.deferred_source = effective.deferred orelse &.{};

    publishBindings(unit, frame);
}

pub fn publishBindings(unit: *project.Unit, frame: *const project.LoadFrame) void {
    unit.signature_aliases = frame.aliases.items;
    unit.signature_imports = frame.imports.items;
    unit.signature_reexports = frame.export_functions.items;
    unit.signature_constant_imports = frame.constant_imports.items;
}
