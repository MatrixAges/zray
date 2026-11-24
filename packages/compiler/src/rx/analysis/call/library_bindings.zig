const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const ir = zx.ir;
const wrapper = @import("compiled_wrapper.zig");
const compiled = frontend.project.compiled;
const Self = @This();
const Error = std.mem.Allocator.Error;

pub const Bound = struct {
    functions: ir.FunctionStorage = .{},
    exports: compiled.ExportIndex,
    checked: []u64 = &.{},
};

pub const Target = struct {
    binding: *Bound,
    export_row: *const compiled.Export,
    pub fn ports(self: Target) frontend.project.signature_project.Ports {
        const function = @backingInt(self.export_row.function.?);

        return .{
            .input_type = @fromBackingInt(self.binding.functions.input_types.items[function]),
            .output_type = @fromBackingInt(self.binding.functions.output_types.items[function]),
        };
    }
    pub fn validate(self: Target, backing: std.mem.Allocator, context: *const frontend.Context, offset: usize, verified_prefix: bool) Error!?zx.Diagnostic {
        var temporary = std.heap.ArenaAllocator.init(backing);

        defer temporary.deinit();

        const id = self.export_row.function.?;
        const binding = self.binding;
        const functions = binding.functions.view();

        const program = try wrapper.build(temporary.allocator(), .{
            .file_name = self.export_row.path,
            .offset = offset,
            .id = id,
            .types = context.types,
            .functions = functions,
            .native_modules = context.native_modules,
        });

        return frontend.validateIrExtending(backing, program, if (verified_prefix) functions else .{});
    }
};

allocator: std.mem.Allocator,
scratch: std.heap.ArenaAllocator,
bound: std.AutoHashMapUnmanaged(usize, *Bound) = .empty,
workspace: ?*compiled.CallWorkspace = null,
pub fn link(self: *Self, project: *frontend.project.Options, index: usize) !*Bound {
    const library = &project.compiled_libraries[index];
    const temporary = self.scratch.allocator();
    const binding = try temporary.create(Bound);
    binding.* = .{ .exports = .{} };
    const context = &project.context;

    const workspace = self.workspace orelse new: {
        const storage = try temporary.create(compiled.CallWorkspace);
        storage.* = try compiled.CallWorkspace.init(self.allocator, context);
        self.workspace = storage;

        break :new storage;
    };

    binding.exports = try compiled.ExportIndex.init(temporary, library.exports.len);

    try workspace.link(self.allocator, library.*, &binding.functions, .{
        .functions = temporary,
        .temporary = self.scratch.child_allocator,
        .export_buckets = binding.exports.buckets(),
    });

    const count = binding.functions.count();

    if (count != 0) {
        binding.checked = try temporary.alloc(u64, count / @bitSizeOf(u64) + 1);

        @memset(binding.checked, 0);
    }

    try binding.exports.finish(library.exports);

    workspace.publish(context);

    try self.bound.put(temporary, index, binding);

    return binding;
}
