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
const Functions = std.meta.Child(@typeInfo(@FieldType(Destinations, "functions")).optional.child);
const FunctionSource = std.meta.Child(@FieldType(Functions, "named"));
const Fallback = std.meta.Child(@typeInfo(@FieldType(Functions, "fallback")).optional.child);

pub const TypeLists = struct {
    exports: []const ir.Export,
    values: []const ir.Constant,
    aliases: *std.ArrayList(ir.Export),
    constants: *std.ArrayList(ir.Constant),
};

pub const FunctionList = struct { members: Members, imports: *std.ArrayList(Binding) };

pub const Publication = struct {
    alias_source: []const memory.NamedId,
    member_ports: Binding.Readable,
    member_source: FunctionSource,
    fallback: Fallback,
    aliases_input: Aliases,
    functions_input: Functions,
    destinations: Destinations,
    pub fn init(self: *Publication, types: TypeLists, functions: ?FunctionList) void {
        self.alias_source = memory.borrowNamedRows("type_id", types.exports);
        self.aliases_input = .{ .source = @ptrCast(&self.alias_source) };

        if (functions) |list| {
            self.member_ports = Binding.Readable.borrowRows(list.members.named);
            self.member_source = self.member_ports.view(FunctionSource);

            if (list.members.default) |member| self.fallback = member.borrow(Fallback);

            self.functions_input = .{
                .named = &self.member_source,
                .fallback = if (list.members.default != null) &self.fallback else null,
            };
        }

        self.destinations = .{
            .aliases = &self.aliases_input,
            .functions = if (functions != null) &self.functions_input else null,
        };
    }
};
