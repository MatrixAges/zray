//! A generator that stays resident between builds. The first build runs the generator as usual and leaves a copy of
//! it serving requests on a Unix socket in the cache directory; later builds hand their request to that copy, which
//! keeps the parsed modules and cached sources in memory instead of reading and parsing them again. The copy analyzes
//! the first build's request again as it starts, so the next build, which usually changes little, already reuses it. A copy built from
//! another executable, or idle for 15 minutes, exits. A request the resident copy cannot finish is run again here,
//! so its diagnostics reach the build. `ZXC_RESIDENT_GENERATOR=0` turns this off.
const std = @import("std");
const Resident = @import("state.zig");
const generator = @import("../generate_parser.zig");
const protocol = @import("compiler").resident_protocol;
const settings = protocol.settings;
const Watch = @import("watch.zig");
const Request = generator.Request;
const Identity = protocol.Identity;
const Status = protocol.Status;

/// Runs `request`, through the resident generator when one serves this executable.
pub fn run(init: std.process.Init, request: Request) !void {
    const allocator = init.arena.allocator();
    const enabled = !disabled(init.environ_map);

    if (enabled) if (try forward(init.io, allocator, request)) |summary| return print(init.io, summary);

    var resident = try Resident.init(init.io, init.gpa);
    const summary = try generator.generate(init.io, allocator, &resident, request);

    resident.endRequest();

    _ = resident.emission.reset(.free_all);

    resident.persist();

    try print(init.io, summary);
    if (enabled) start(init, allocator, request) catch {};
}

/// Serves requests on the socket in `cache` until idle or asked by another executable, after
/// analyzing `warm`. Requests arriving meanwhile wait on the socket.
pub fn serve(init: std.process.Init, cache: []const u8, warm: ?Request) !void {
    const io = init.io;
    const path = try socketPath(init.arena.allocator(), cache);
    const address = std.Io.net.UnixAddress.init(path) catch return;

    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var server = address.listen(io, .{}) catch return;

    defer server.deinit(io);

    var resident = try Resident.init(io, init.gpa);
    resident.profile_memory = if (init.environ_map.get(settings.memory_name)) |value| std.mem.eql(u8, value, settings.memory_value) else false;
    const identity = try ownIdentity(io, init.arena.allocator());
    var watch = Watch{ .io = io, .path = path, .resident = &resident };
    const thread = try std.Thread.spawn(.{}, Watch.run, .{&watch});

    if (warm) |request| {
        _ = generator.generate(io, resident.requestAllocator(), &resident, request) catch {};

        resident.endRequest();
    }

    watch.finish();

    while (true) {
        const stream = server.accept(io) catch continue;

        if (!watch.begin()) {
            stream.close(io);
            thread.join();
            unreachable;
        }

        defer stream.close(io);

        const status = answer(io, &resident, &identity, stream) catch .Failed;

        resident.logMemory();

        if (status == .Stale) {
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
            std.process.exit(0);
        }

        watch.finish();
    }
}

/// Reads one request, runs it, and replies with its status and summary.
fn answer(io: std.Io, resident: *Resident, identity: *const Identity, stream: std.Io.net.Stream) !Status {
    const allocator = resident.requestAllocator();

    defer resident.endRequest();

    var input_buffer: [4096]u8 = undefined;
    var output_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &input_buffer);
    var writer = stream.writer(io, &output_buffer);
    const message = try protocol.receive(allocator, &reader.interface);
    const here = try std.process.currentPathAlloc(io, allocator);
    var status = protocol.admit(identity, &message, here);
    var summary: []const u8 = "";

    if (status == .Done) {
        if (generator.generate(io, allocator, resident, message.request)) |generated| {
            summary = generated;
        } else |_| status = .Failed;
    }

    try protocol.reply(allocator, &writer.interface, status, summary);
    try writer.interface.flush();

    return status;
}

/// Hands `request` to the resident generator; null when none answers for this executable and directory.
fn forward(io: std.Io, allocator: std.mem.Allocator, request: Request) !?[]const u8 {
    const path = try socketPath(allocator, request.cache);
    const address = std.Io.net.UnixAddress.init(path) catch return null;
    const stream = address.connect(io) catch return null;

    defer stream.close(io);

    // A resident generator that stops answering must not hold up the build: past the limit the request runs here.
    for ([_]u32{ std.c.SO.RCVTIMEO, std.c.SO.SNDTIMEO }) |option| {
        const limit = std.c.timeval{ .sec = @intCast(settings.reply_timeout_seconds), .usec = 0 };

        std.posix.setsockopt(stream.socket.handle, std.c.SOL.SOCKET, option, std.mem.asBytes(&limit)) catch return null;
    }

    const identity = try ownIdentity(io, allocator);
    var input_buffer: [4096]u8 = undefined;
    var output_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &output_buffer);
    var reader = stream.reader(io, &input_buffer);
    const cwd = try std.process.currentPathAlloc(io, allocator);

    protocol.send(allocator, &writer.interface, identity, cwd, request) catch return null;
    writer.interface.flush() catch return null;

    return protocol.readSummary(allocator, &reader.interface) catch null;
}

/// Starts a resident copy of this executable for later builds, detached from the build that ran `request`.
fn start(init: std.process.Init, allocator: std.mem.Allocator, request: Request) !void {
    const executable = try std.process.executablePathAlloc(init.io, allocator);
    var environ = try init.environ_map.clone(allocator);

    // The build runner reads this process's progress pipe until every holder closes it, so the copy must not inherit it.
    if (environ.get("ZIG_PROGRESS")) |descriptor| {
        _ = std.c.fcntl(try std.fmt.parseInt(std.c.fd_t, descriptor, 10), std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        _ = environ.swapRemove("ZIG_PROGRESS");
    }

    _ = try std.process.spawn(init.io, .{
        .argv = &.{ executable, settings.serve_command, request.cache, request.manifest, request.output, try std.fmt.allocPrint(allocator, "{d}", .{request.partitions}) },
        .environ_map = &environ,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
}

fn ownIdentity(io: std.Io, allocator: std.mem.Allocator) !Identity {
    const path = try std.process.executablePathAlloc(io, allocator);
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});

    return Identity.init(stat.size, stat.mtime.nanoseconds, path);
}

fn socketPath(allocator: std.mem.Allocator, cache: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ cache, settings.socket_name });
}

fn disabled(environ: *const std.process.Environ.Map) bool {
    const value = environ.get(settings.enabled_name) orelse return false;

    return std.mem.eql(u8, value, settings.disabled_value);
}

fn print(io: std.Io, summary: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, summary);
}
