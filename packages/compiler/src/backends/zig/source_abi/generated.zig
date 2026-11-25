const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const project = @import("frontend").project;
const view = @import("genz").zx.modules.abi_view;
const generated = @import("generated_source_abi");
const Input = std.meta.Child(generated.Input);
const Bindings = std.meta.Child(@FieldType(Input, "modules"));
const Sources = std.meta.Child(@FieldType(Input, "fallback"));
const Scopes = std.meta.Child(@FieldType(Input, "scopes"));
const Lists = std.meta.Child(@FieldType(Sources, "interfaces"));
const fields = .{ .specifiers = "specifier", .identities = "identity" };

pub fn render(allocator: std.mem.Allocator, modules: ir.NativeModuleTable, options: project.Options) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const temporary = buffered.allocator();
    const scopes = options.package_scopes;
    const roots = memory.borrowTextColumn("root", scopes);
    const interfaces = memory.borrowListFields(&.{"native_interfaces"}, fields, scopes);
    const externals = memory.borrowListFields(&.{"externals"}, fields, scopes);

    const defaults: []const project.PackageScope = &.{.{
        .root = options.root_dir,
        .packages = &.{},
        .native_interfaces = options.native_interfaces,
        .externals = options.externals,
    }};

    const default_interfaces = memory.borrowListFields(&.{"native_interfaces"}, fields, defaults);
    const default_externals = memory.borrowListFields(&.{"externals"}, fields, defaults);

    const input: Input = .{
        .modules = &Bindings{ .specifiers = modules.specifiers, .identities = modules.identities },
        .scopes = &Scopes{
            .count = scopes.len,
            .roots = @ptrCast(&roots),
            .interfaces = &interfaces.bind(Lists),
            .externals = &externals.bind(Lists),
        },
        .fallback = &Sources{ .interfaces = &default_interfaces.bind(Lists), .externals = &default_externals.bind(Lists) },
        .root = options.root_dir,
    };

    const output = generated.executeIn(temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    return if (output) |aliases| view.renderBorrowed(allocator, &.{}, aliases, false) else allocator.dupe(u8, "");
}
