const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const Binding = @import("../../function_import.zig");
const Members = @import("../members.zig");
const generated = @import("generated_project_binding_delivery");
const Input = std.meta.Child(generated.Input);
const Destinations = std.meta.Child(@FieldType(Input, "destinations"));
const Aliases = std.meta.Child(@FieldType(Destinations, "aliases"));
const Constants = std.meta.Child(@FieldType(Destinations, "constants"));
const Functions = std.meta.Child(@typeInfo(@FieldType(Destinations, "functions")).optional.child);
const ConstantSource = std.meta.Child(@FieldType(Constants, "source"));
const FunctionSource = std.meta.Child(@FieldType(Functions, "named"));
const Fallback = std.meta.Child(@typeInfo(@FieldType(Functions, "fallback")).optional.child);

pub const TypeLists = struct {
    exports: []const ir.Export,
    values: []const ir.Constant,
    aliases: *std.ArrayList(ir.Export),
    constants: *std.ArrayList(ir.Constant),
};

pub const FunctionList = struct { members: Members, imports: *std.ArrayList(Binding) };
const AliasTail = Tail(ir.Export, Aliases, .{ .id = &.{"type_id"} });

const ConstantTail = Tail(ir.Constant, Constants, .{
    .names = &.{"name"},
    .types = &.{"type_id"},
    .values = &.{"value"},
});

const FunctionTail = Tail(Binding, Functions, .{});

pub const Publication = struct {
    aliases: AliasTail,
    constants: ConstantTail,
    functions: FunctionTail,
    alias_source: []const memory.NamedId,
    constant_types: memory.ReadColumn,
    constant_values: memory.ReadColumn,
    constant_source: ConstantSource,
    member_ports: Binding.Readable,
    member_source: FunctionSource,
    fallback: Fallback,
    aliases_input: Aliases,
    constants_input: Constants,
    functions_input: Functions,
    destinations: Destinations,
    pub fn init(self: *Publication, types: TypeLists, functions: ?FunctionList) void {
        self.aliases.init(types.aliases);
        self.constants.init(types.constants);

        self.alias_source = memory.borrowNamedRows("type_id", types.exports);
        self.constant_types = memory.borrowReadColumn(ir.TypeId, "type_id", types.values);
        self.constant_values = memory.borrowReadColumn(ir.ConstantValue, "value", types.values);
        self.constant_source = .{ .types = @ptrCast(&self.constant_types), .values = @ptrCast(&self.constant_values) };

        self.aliases_input = .{
            .source = @ptrCast(&self.alias_source),
            .target = &self.aliases.output.view,
            .storage = @ptrCast(&self.aliases.output.buffer),
            .used = @ptrCast(&self.aliases.used),
        };

        self.constants_input = .{
            .source = &self.constant_source,
            .target = &self.constants.output.view,
            .storage = @ptrCast(&self.constants.output.buffer),
            .used = @ptrCast(&self.constants.used),
        };

        if (functions) |list| {
            self.functions.init(list.imports);

            self.member_ports = Binding.Readable.borrowRows(list.members.named);
            self.member_source = self.member_ports.view(FunctionSource);

            if (list.members.default) |member| self.fallback = member.borrow(Fallback);

            self.functions_input = .{
                .named = &self.member_source,
                .fallback = if (list.members.default != null) &self.fallback else null,
                .target = &self.functions.output.view,
                .storage = @ptrCast(&self.functions.output.buffer),
                .used = @ptrCast(&self.functions.used),
            };
        }

        self.destinations = .{
            .aliases = &self.aliases_input,
            .constants = &self.constants_input,
            .functions = if (functions != null) &self.functions_input else null,
        };
    }

    pub fn commit(self: *Publication) void {
        self.aliases.commit();
        self.constants.commit();

        if (self.destinations.functions != null) self.functions.commit();
    }
};

fn Tail(comptime Row: type, comptime Destination: type, comptime fields: anytype) type {
    const Columns = std.meta.Child(@FieldType(Destination, "target"));

    return struct {
        const Self = @This();
        list: *std.ArrayList(Row),
        output: memory.RowOutput(Row, Columns, fields),
        length: u64,
        used: []u64,
        fn init(self: *Self, list: *std.ArrayList(Row)) void {
            self.list = list;

            self.output.init();
            self.output.bind(list.allocatedSlice());

            self.length = list.items.len;
            self.used = @as(*[1]u64, @ptrCast(&self.length));
        }
        fn commit(self: *Self) void {
            const rows = self.output.rows();

            self.list.items = rows[0..@intCast(self.length)];
            self.list.capacity = rows.len;
        }
    };
}
