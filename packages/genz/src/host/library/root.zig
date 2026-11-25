const std = @import("std");
const zx = @import("zx");
const entry = @import("generated_library_build");
const Input = std.meta.Child(entry.Input);
pub const Module = std.meta.Child(std.meta.Child(@FieldType(Input, "generated")));
pub const Native = std.meta.Child(std.meta.Child(@FieldType(Input, "native")));

pub const Options = struct {
    native: []const Native,
    generated: []const Module,
    public: []const Module,
    libraries: []const []const u8,
    library_paths: []const []const u8,
};

pub const Error = std.mem.Allocator.Error || error{UnknownModuleDependency};

pub fn render(allocator: std.mem.Allocator, options: Options) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const workspace = arena.allocator();

    const input: Input = .{
        .native = try zx.columns.pointers(@FieldType(Input, "native"), workspace, options.native),
        .generated = try zx.columns.pointers(@FieldType(Input, "generated"), workspace, options.generated),
        .public = try zx.columns.pointers(@FieldType(Input, "public"), workspace, options.public),
        .libraries = options.libraries,
        .library_paths = options.library_paths,
    };

    const output = zx.columns.invoke(entry.executeValue, workspace, &input) catch |err| return failure(err);

    if (output.status != .Ready) return error.UnknownModuleDependency;
    if (!output.valid) return error.OutOfMemory;

    return @import("../../printer/module.zig").render(allocator, workspace, std.meta.Child(entry.Output), output);
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid library build AST"),
    };
}
