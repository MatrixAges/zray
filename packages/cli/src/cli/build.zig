const std = @import("std");
const Options = @import("options.zig").Options;
const project = @import("project.zig");
const Loaded = project.Loaded;
const artifacts = @import("artifacts.zig");
const Cache = @import("build/observed.zig").Cache;
pub const Observed = @import("build/observed.zig");
const Staged = @import("build/staged.zig");
const Translation = @import("build/translation.zig");
const Command = @import("build/command.zig");
const Emission = union(enum) { staged: Staged, observed: Cache };

pub fn run(io: std.Io, allocator: std.mem.Allocator, bundle: @import("compiler").zig.ModuleBundle, options: Options, loaded: Loaded, toolchain: @import("toolchain.zig").Paths, environment: *const std.process.Environ.Map) !bool {
    const bindings = try @import("node/bindings.zig").create(allocator, bundle, options);

    if (bindings) |files| try files.check(io, allocator, options);

    const staged = try Staged.init(io, allocator, options);

    defer staged.deinit(io);

    var backend_environment = try environmentFor(allocator, environment, toolchain.library);

    defer backend_environment.deinit();

    var translation = Translation.init(allocator, try Cache.init(io, allocator, environment));

    defer translation.deinit();

    const arguments = try prepare(io, allocator, bundle, options, loaded, toolchain, .{ .staged = staged }, &translation, &backend_environment) orelse {
        var buffer: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &buffer);

        try stderr.interface.writeAll(translation.failure.?.stderr);
        try translation.failure.?.diagnostics.renderToWriter(.{}, &stderr.interface);
        try stderr.interface.flush();

        return false;
    };

    var child = try std.process.spawn(io, .{ .argv = arguments, .environ_map = &backend_environment });
    const termination = try child.wait(io);

    if (termination != .exited or termination.exited != 0) return false;

    if (bindings) |files| {
        try files.check(io, allocator, options);
        try files.stage(io, allocator, std.fs.path.dirname(staged.binary).?);
    }

    try staged.publish(io, allocator, options);

    return true;
}

pub fn runObserved(io: std.Io, allocator: std.mem.Allocator, bundle: @import("compiler").zig.ModuleBundle, options: Options, loaded: Loaded, toolchain: @import("toolchain.zig").Paths, environment: *const std.process.Environ.Map, inputs: *@import("watch/inputs.zig")) !Observed {
    const cache = try Cache.init(io, allocator, environment);
    var backend_environment = try environmentFor(allocator, environment, toolchain.library);

    defer backend_environment.deinit();

    var translation = Translation.init(allocator, cache);

    defer translation.deinit();

    const arguments = try prepare(io, allocator, bundle, options, loaded, toolchain, .{ .observed = cache }, &translation, &backend_environment);
    var response = if (arguments) |argv| try @import("backend/process.zig").run(io, allocator, argv, &backend_environment) else translation.failure.?;

    translation.failure = null;

    errdefer response.deinit();

    try translation.merge(&response);

    var observed = try Observed.resolve(io, &response, cache, toolchain.library, options, inputs);

    observed.bindings = try @import("node/bindings.zig").create(response.arena.allocator(), bundle, options);

    return observed;
}

fn prepare(io: std.Io, allocator: std.mem.Allocator, bundle: @import("compiler").zig.ModuleBundle, options: Options, loaded: Loaded, toolchain: @import("toolchain.zig").Paths, emission: Emission, translation: *Translation, environment: *const std.process.Environ.Map) !?[]const []const u8 {
    if (bundle.signature) |signature| {
        const ir = @import("compiler").ir;

        if (try ir.containsNativeReference(allocator, signature.types, signature.input) or try ir.containsNativeReference(allocator, signature.types, signature.output)) return error.UnsupportedHostReference;
    }

    var configuration_options = options;
    configuration_options.cache = true;
    configuration_options.cache_stats = false;
    configuration_options.watch = false;
    configuration_options.run = false;
    configuration_options.run_args = &.{};
    const node = options.host == .node;
    const node_signature = if (node) bundle.signature orelse return error.MissingNodeSignature else null;
    var node_sources = if (node_signature) |signature| try @import("node/resources.zig").create(allocator, bundle.state_module != null, signature.types, signature.input, signature.output) else null;

    defer if (node_sources) |*sources| sources.deinit();

    const configuration = try std.json.Stringify.valueAlloc(allocator, .{ .options = configuration_options, .project = loaded, .node_host_sources = if (node_sources) |*sources| @as([]const @import("node/resources.zig").File, &sources.files) else &.{}, .node_sources = if (node_sources) |*sources| @as([]const @import("node/resources.zig").File, &sources.napi) else &.{} }, .{});
    const abi = try @import("abi.zig").create(allocator, bundle, loaded);
    const wasm = try @import("wasm/target.zig").freestanding(options.target);
    var executable_bundle = bundle;

    if (node) {
        if (wasm or bundle.runner != null) return error.UnsupportedNodeRunner;

        executable_bundle.runner = try @import("compiler").zig.host.node.runner(allocator, bundle.state_module != null);
    }

    if (wasm) {
        if (bundle.runner != null) return error.UnsupportedWasmRunner;

        const signature = bundle.signature orelse return error.MissingApplicationSignature;

        executable_bundle.runner = try @import("compiler").zig.host.wasm(allocator, bundle.state_module != null, .{ .types = signature.types, .id = signature.output });
    }

    defer if (wasm or node) allocator.free(executable_bundle.runner.?);

    const directory = try artifacts.prepare(io, allocator, executable_bundle, configuration, abi, options.result == .json);
    var arguments = Command{ .allocator = allocator };
    var node_library: ?[]const u8 = null;

    if (node) {
        const target = if (options.target) |triple| try std.Target.Query.parse(.{ .arch_os_abi = triple }) else std.Target.Query.fromTarget(&@import("builtin").target);
        const os = target.os_tag orelse @import("builtin").os.tag;
        const arch = target.cpu_arch orelse @import("builtin").cpu.arch;

        if (arch == .wasm32 or arch == .wasm64) return error.UnsupportedNodeTarget;
        if (os == .windows and options.node_library == null) return error.NodeImportLibraryRequired;
        if (options.node_library) |path| node_library = try std.fs.path.resolve(allocator, &.{path});
        for (node_sources.?.files) |file| try artifacts.retain(io, allocator, try std.fs.path.join(allocator, &.{ directory, "node", file.path }), file.source);
        for (node_sources.?.napi) |file| try artifacts.retain(io, allocator, try std.fs.path.join(allocator, &.{ directory, "napi", file.path }), file.source);
    }

    if (emission == .staged) {
        try ensureParent(io, emission.staged.binary);
        if (emission.staged.assembly) |path| try ensureParent(io, path);
    }

    const modules = loaded.config.native_modules;
    const native_names = try allocator.alloc([]const u8, modules.len);
    var libc = false;

    for (modules, native_names) |module, *name| {
        name.* = module.name;
        libc = libc or module.header != null;
    }

    try arguments.prefix(.{
        .tool = toolchain.executable,
        .library = toolchain.library,
        .node = node,
        .wasm = wasm,
        .node_library = node_library,
        .server = if (emission == .observed) &.{
            .name = Observed.artifact_name,
            .root = emission.observed.cwd,
            .local = emission.observed.local,
            .global = emission.observed.global,
            .assembly = options.assembly != null,
        } else null,
        .files = if (emission == .staged) &.{
            .binary = emission.staged.binary,
            .assembly = emission.staged.assembly,
        } else null,
        .libraries = loaded.config.libraries,
        .library_paths = try resolvePaths(allocator, loaded.project.root_dir, loaded.config.library_paths),
        .libc = libc,
    });

    var settings_buffer: [Command.constants.settings_capacity][]const u8 = undefined;
    const settings = try Command.settings(allocator, &settings_buffer, try targetOptions(allocator, options));

    try arguments.entry(.{
        .settings = settings,
        .directory = directory,
        .node = node,
        .state = bundle.state_module,
        .imports = bundle.entry.imports,
        .natives = native_names,
    });

    for (bundle.modules) |module| {
        try arguments.module(.{
            .settings = settings,
            .name = module.name,
            .path = try artifacts.modulePath(allocator, module),
            .imports = module.imports,
            .includes = &.{},
            .canonical = true,
            .abi = null,
            .translated = null,
        });
    }

    for (modules) |module| {
        const abi_index = project.nativeIndex("module", abi.views, module.name, false);
        const scope = project.nativeScope(loaded, module);
        const includes = try resolvePaths(allocator, scope.root, scope.paths);

        var planned: Command.Module = .{
            .settings = settings,
            .name = module.name,
            .path = undefined,
            .imports = module.dependencies,
            .includes = includes,
            .canonical = true,
            .abi = if (abi_index) |index| abi.views[index].name else null,
            .translated = null,
        };

        if (module.path) |path| {
            planned.path = try std.fs.path.resolve(allocator, &.{ loaded.project.root_dir, path });
        } else {
            planned.path = try std.fmt.allocPrint(allocator, "{s}/native/{s}.zig", .{ directory, module.name });
            const header_path = try std.fmt.allocPrint(allocator, "{s}/native/{s}.h", .{ directory, module.name });
            const include = try std.json.Stringify.valueAlloc(allocator, module.header.?, .{});
            const header_source = try std.fmt.allocPrint(allocator, "#include {s}\n", .{include});
            var command = Command{ .allocator = allocator };

            try artifacts.retain(io, allocator, header_path, header_source);

            try command.translate(.{
                .tool = toolchain.executable,
                .library = toolchain.library,
                .local = translation.cache.local,
                .global = translation.cache.global,
                .settings = settings,
                .includes = includes,
                .header = header_path,
            });

            planned.translated = try translation.execute(io, command.arguments.items, environment, module.name) orelse return null;

            const adapter = try @import("compiler").zig.host.cAdapter(allocator);

            defer allocator.free(adapter);

            try artifacts.retain(io, allocator, planned.path, adapter);
        }

        try arguments.module(planned);
    }

    for (abi.views) |view| {
        try arguments.module(.{
            .settings = settings,
            .name = view.name,
            .path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, view.path }),
            .imports = &.{Command.constants.canonical_dependency},
            .includes = &.{},
            .canonical = false,
            .abi = null,
            .translated = null,
        });
    }

    try arguments.module(.{
        .settings = settings,
        .name = Command.constants.abi_module,
        .path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, Command.constants.abi_source }),
        .imports = &.{},
        .includes = &.{},
        .canonical = false,
        .abi = null,
        .translated = null,
    });

    if (node) {
        try arguments.module(.{
            .settings = settings,
            .name = Command.constants.napi_module,
            .path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, Command.constants.napi_source }),
            .imports = &.{Command.constants.application_module},
            .includes = &.{},
            .canonical = false,
            .abi = null,
            .translated = null,
        });
    }

    const manifest = try std.json.Stringify.valueAlloc(allocator, arguments.arguments.items, .{ .whitespace = .indent_2 });

    try artifacts.write(io, try std.fs.path.join(allocator, &.{ directory, "command.json" }), manifest);

    return arguments.arguments.items;
}

fn environmentFor(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, library: []const u8) !std.process.Environ.Map {
    var result = std.process.Environ.Map.init(allocator);

    errdefer result.deinit();

    for (environment.keys(), environment.values()) |key, value| try result.put(key, value);
    try result.put("ZIG_LIB_DIR", library);

    return result;
}

fn targetOptions(allocator: std.mem.Allocator, options: Options) !Command.Settings {
    const builtin = @import("builtin");
    const host = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
    const target = options.target orelse if (!std.mem.eql(u8, host, @import("bundle").zig_host)) try builtin.target.zigTriple(allocator) else null;

    return .{ .optimize = @tagName(options.optimize), .target = target, .cpu = options.cpu };
}

fn resolvePaths(allocator: std.mem.Allocator, root: []const u8, paths: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, paths.len);

    for (paths, result) |path, *resolved| resolved.* = try std.fs.path.resolve(allocator, &.{ root, path });

    return result;
}

fn ensureParent(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    var directory = try std.Io.Dir.cwd().createDirPathOpen(io, parent, .{});

    directory.close(io);
}
