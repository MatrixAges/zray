const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const frontend = @import("frontend");
const Compiler = @import("../flow_compile.zig");
const Module = @import("../module.zig");
const Self = @This();

row: u32,
invocation: Module.Call,
input: ?*const rx.ast.Attribute,
pub fn prepare(compiler: *Compiler, row: u32, work: *Self) Compiler.Error!void {
    const options = compiler.inputs;
    const id = options.ids[row];
    const base = options.shared_functions;
    const callee = try @import("../project/mixed/function.zig").programView(compiler.metadataAllocator(), base.at(@backingInt(id)), id, base, options.types, options.native_modules);
    const loop = try @import("loop.zig").compile(compiler, row, callee);
    const input = options.calls.items(.input)[row];

    work.row = row;
    work.input = input;
    work.invocation.function_id = id;
    work.invocation.callee = callee;
    work.invocation.store_initializers = options.store_initializers;
    work.invocation.input_omitted = input == null;
    work.invocation.loop = loop;
    work.invocation.getters = options.calls.items(.getters)[row];
    work.invocation.callee_suffix = null;
}

pub fn bindGetters(self: *const Self, compiler: *Compiler) Compiler.Error!void {
    try @import("../store/bindings.zig").typed(&compiler.bindings, compiler.binding_allocator, self.invocation.getters);
}

pub fn argument(self: *Self, compiler: *Compiler) Compiler.Error!void {
    const attribute = self.input.?;
    const expected = self.invocation.callee.input_type;

    self.invocation.argument = if (@import("../project/call_inputs.zig").input(compiler.inputs.arguments, self.row)) |parsed|
        try compiler.valueParsed(parsed, attribute.*, expected, compiler.retain_metadata)

    else
        try compiler.value(attribute.*, expected, compiler.retain_metadata);
}

pub fn unit(self: *Self, compiler: *Compiler) Compiler.Error!void {
    self.invocation.argument = try @import("../call/unit.zig").create(compiler.metadataAllocator(), compiler.owner, compiler.types, compiler.inputs.calls.items(.node)[self.row].location);
}

pub fn publish(self: *Self, compiler: *Compiler, outputs: *frontend.expressions.BindingStorage, result: Compiler.Result) Compiler.Error!u32 {
    try result.publish(compiler.binding_allocator, outputs);

    self.invocation.out = result.name;

    return compiler.appendCall(self.invocation);
}
