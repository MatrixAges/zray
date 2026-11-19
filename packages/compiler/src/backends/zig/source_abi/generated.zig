const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const project = @import("frontend").project;
const view = @import("genz").zx.modules.abi_view;
const generated = @import("generated_source_abi");
const Input = std.meta.Child(generated.Input);
const Bindings = std.meta.Child(@FieldType(Input, "modules"));
const Sources = std.meta.Child(@FieldType(Input, "sources"));

pub fn render(allocator: std.mem.Allocator, modules: ir.NativeModuleTable, options: project.Options) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const temporary = buffered.allocator();
    const roots = memory.borrowTextColumn("root", options.package_scopes);
    const planner = @import("generated_source_abi_plan");
    const plan: std.meta.Child(planner.Input) = .{ .identities = modules.identities, .count = options.package_scopes.len, .roots = @ptrCast(&roots), .root = options.root_dir };

    const selected = planner.executeIn(temporary, &plan) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    if (!selected.scoped) return allocator.dupe(u8, "");

    const configured = if (selected.scope) |index| options.package_scopes[index] else project.PackageScope{
        .root = options.root_dir,
        .packages = &.{},
        .native_interfaces = options.native_interfaces,
        .externals = options.externals,
    };

    const module_bindings: Bindings = .{ .specifiers = modules.specifiers, .identities = modules.identities };
    const interfaces = Columns.init(configured.native_interfaces);
    const externals = Columns.init(configured.externals);
    const interface_view = interfaces.view();
    const external_view = externals.view();
    const configured_sources: Sources = .{ .interfaces = &interface_view, .externals = &external_view };
    const input: Input = .{ .modules = &module_bindings, .sources = &configured_sources };

    const output = generated.executeIn(temporary, &input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return view.renderBorrowed(allocator, &.{}, output, false);
}

const Columns = struct {
    specifiers: memory.TextColumn,
    identities: memory.ReadColumn,
    fn init(values: anytype) Columns {
        return .{
            .specifiers = memory.borrowTextColumn("specifier", values),
            .identities = memory.borrowReadColumn(?[]const u8, "identity", values),
        };
    }

    fn view(self: *const Columns) std.meta.Child(@FieldType(Sources, "interfaces")) {
        return .{ .count = self.specifiers.count, .specifiers = @ptrCast(&self.specifiers), .identities = @ptrCast(&self.identities) };
    }
};
