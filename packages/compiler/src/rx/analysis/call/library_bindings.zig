const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const ir = zx.ir;
const wrapper = @import("compiled_wrapper.zig");
const compiled = frontend.project.compiled;
const Self = @This();
const Error = std.mem.Allocator.Error;

const Bound = struct {
    functions: ir.FunctionStorage = .{},
    exports: compiled.ExportIndex,
    checked: std.DynamicBitSetUnmanaged,
    validated: bool = false,
};

pub const Selection = union(enum) { Ready: Target, Missing, Conflict, Unlinked, MissingExport };

pub const Target = struct {
    binding: *Bound,
    export_row: *const compiled.Export,
    pub fn checked(self: Target) bool {
        const id = self.export_row.function orelse return false;

        return self.binding.checked.isSet(@backingInt(id));
    }
    pub fn ports(self: Target) frontend.project.signature_project.Ports {
        const function = @backingInt(self.export_row.function.?);

        return .{
            .input_type = @fromBackingInt(self.binding.functions.input_types.items[function]),
            .output_type = @fromBackingInt(self.binding.functions.output_types.items[function]),
        };
    }
    pub fn validate(self: Target, backing: std.mem.Allocator, context: *const frontend.Context, offset: usize) Error!?zx.Diagnostic {
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

        if (try frontend.validateIrExtending(backing, program, if (binding.validated) functions else .{})) |issue| return issue;

        binding.validated = true;

        binding.checked.set(@backingInt(id));

        return null;
    }
};

allocator: std.mem.Allocator,
scratch: std.heap.ArenaAllocator,
bound: std.AutoHashMapUnmanaged(usize, *Bound) = .empty,
pub fn select(self: *Self, project: *frontend.project.Options, selected: compiled.Target) Error!Selection {
    const libraries = project.compiled_libraries;

    const index = switch (try compiled.resolve.library(self.scratch.child_allocator, libraries, project.root_dir, selected)) {
        .found => |value| value,
        .conflict => return .Conflict,
        .missing => return .Missing,
    };

    const library = &libraries[index];

    const binding = self.bound.get(index) orelse block: {
        const loaded = self.load(project, library) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return .Unlinked;
        };

        try self.bound.put(self.scratch.allocator(), index, loaded);

        break :block loaded;
    };

    const row = binding.exports.find(library.exports, selected.name) orelse return .MissingExport;

    return .{ .Ready = .{ .binding = binding, .export_row = &library.exports[row] } };
}

fn load(self: *Self, project: *frontend.project.Options, library: *const compiled.Library) !*Bound {
    const temporary = self.scratch.allocator();
    const binding = try temporary.create(Bound);
    binding.* = .{ .exports = .{}, .checked = .{} };
    const context = &project.context;
    var natives = try frontend.native_context.storage(self.allocator, context.native_modules);

    binding.exports = try compiled.ExportIndex.init(temporary, library.exports.len);

    const result = try compiled.loadCalls(self.allocator, .{
        .functions = temporary,
        .temporary = self.scratch.child_allocator,
        .export_buckets = binding.exports.buckets(),
    }, .{
        .library = library.*,
        .types = context.types,
        .nominal_types = context.nominal_types,
        .functions = &binding.functions,
        .native_modules = &natives,
    });

    binding.checked = try std.DynamicBitSetUnmanaged.initEmpty(temporary, binding.functions.count());

    try binding.exports.finish(library.exports);

    context.types = result.types;
    context.nominal_types = result.nominal_types;
    context.native_modules = natives.view();

    return binding;
}
