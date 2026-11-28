const std = @import("std");
const compiler = @import("compiler");
const project = @import("../../project.zig");
const Inputs = @import("watch_inputs").Inputs;
const host = @import("publication_host");
const abi = @import("../../abi.zig");
const layout = @import("../publication/layout.zig");
const resources = @import("../resources.zig");
const memory = @import("zx").memory;
const source = @import("cli_source");
const Input = std.meta.Child(source.library_stage_write.Input);
const constants = source.library_publication_constants.@"zx.constants";
const Files = std.meta.Child(@FieldType(Input, "files"));
const Rows = std.meta.Child(@FieldType(Files, "aliases"));
pub const Error = host.effects.Error;

pub const Request = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    backing: std.mem.Allocator,
    directory: []const u8,
    library: *const compiler.library.Result,
    bundle: *const compiler.zig.LibraryBundle,
    loaded: *const project.Loaded,
    inputs: ?*Inputs,
};

pub const State = struct {
    request: Request,
    resources: *const resources.State,
    failure: *host.Failure,
    disk: @import("artifact_io").DirectoryWriter,
    abi: abi.Result = undefined,
    layout: layout.Plan = undefined,
    config: project.Config = undefined,
    managed: []const host.inventory.File = &.{},
    aliases: FileRows = undefined,
    generated: FileRows = undefined,
    public: FileRows = undefined,
    files: Files = undefined,
    pub fn get(handle: *const anyopaque) *State {
        return host.effects.state(State, handle);
    }
    pub fn borrowFiles(self: *State) void {
        const bundle = self.request.bundle;

        self.aliases.init(self.abi.views, &.{"source"}, self.abi.views);
        self.generated.init(self.layout.generated, &.{"source"}, bundle.modules);
        self.public.init(self.layout.public, &.{ "file", "source" }, bundle.public_modules);

        self.files = .{ .abi_path = constants.abi_file, .abi = self.abi.source, .aliases = &self.aliases.rows, .generated = &self.generated.rows, .public = &self.public.rows };
    }
};

const FileRows = struct {
    paths: memory.TextColumn,
    sources: memory.TextColumn,
    rows: Rows,
    fn init(self: *FileRows, paths: anytype, comptime field: []const []const u8, sources: anytype) void {
        self.paths = memory.borrowTextColumn("path", paths);
        self.sources = memory.borrowNestedColumn([]const u8, field, sources);
        self.rows = .{ .count = paths.len, .paths = @ptrCast(&self.paths), .sources = @ptrCast(&self.sources) };
    }
};
