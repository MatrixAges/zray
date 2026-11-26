const std = @import("std");
const rx = @import("rx");
const compiler = @import("compiler");
const selection = compiler.resident_modules;
const Self = @This();

const Version = struct {
    path: []const u8,
    parsed: rx.IndexedXml,
    capacity: usize,
    readers: usize = 1,
};

pub const Batch = struct {
    versions: []*Version,
    packages: [32]u8,
    readers: usize = 1,
};

gpa: std.mem.Allocator,
current: ?*Batch = null,
pending: ?*Batch = null,
capacity: usize = 0,
versions: usize = 0,
parsed: usize = 0,
reused: usize = 0,
pub fn deinit(self: *Self) void {
    self.discard();

    if (self.current) |batch| self.release(batch);

    std.debug.assert(self.versions == 0);
}

fn isStore(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".store.rx");
}

/// Borrows unchanged XML and stages new versions until an analysis publishes them. Sources are sorted by path.
pub fn prepare(self: *Self, owner: std.mem.Allocator, sources: []const rx.TextSource, packages: [32]u8) ![]const rx.ModuleSource {
    std.debug.assert(self.pending == null);

    const inputs = try owner.alloc(rx.ModuleSource, sources.len);
    const before = if (self.current) |batch| batch.versions else &.{};
    const previous_packages = if (self.current) |batch| &batch.packages else null;
    var scratch = std.heap.ArenaAllocator.init(self.gpa);

    defer scratch.deinit();

    const plan = try selection.prepare(scratch.allocator(), before, sources, previous_packages, &packages);

    if (plan.whole) {
        for (before, inputs, sources) |version, *input, source| input.* = view(version, source, !isStore(source.path));

        self.reused += before.len;

        return inputs;
    }

    const batch = try self.gpa.create(Batch);

    errdefer self.gpa.destroy(batch);

    const next = try self.gpa.alloc(*Version, sources.len);

    errdefer self.gpa.free(next);

    var initialized: usize = 0;

    errdefer for (next[0..initialized]) |version| self.releaseVersion(version);

    for (sources, inputs, next, 0..) |source, *input, *version, row| {
        const position = plan.at(row);
        const reused = position != 0;

        if (reused) {
            version.* = before[@intCast(position - 1)];
            version.*.readers += 1;
            self.reused += 1;
        } else {
            self.parsed += 1;
            version.* = try self.parse(source);
        }

        initialized += 1;
        input.* = view(version.*, source, reused and !isStore(source.path));
    }

    var store_count: usize = 0;

    for (inputs) |input| {
        if (isStore(input.path)) store_count += 1;
    }

    if (store_count == 0) {
        var checked = try rx.validateModulePaths(self.gpa, inputs);

        defer checked.deinit();

        if (checked.value == .diagnostic) {
            const issue = checked.value.diagnostic;

            return invalid(sources[issue.source_index].path, issue.issue);
        }

        for (inputs, next) |*input, version| rx.markModuleSchema(input, &version.parsed.xml.value.node);
    } else {
        const regular_count = inputs.len - store_count;
        const regular = try scratch.allocator().alloc(rx.ModuleSource, regular_count);
        const regular_indices = try scratch.allocator().alloc(usize, regular_count);
        var regular_pos: usize = 0;

        for (inputs, 0..) |input, row| {
            if (isStore(input.path)) {
                rx.validateSourcePath(self.gpa, input.path, .store) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;

                    return invalid(input.path, .{
                        .code = .context,
                        .location = input.node.location,
                        .element = input.node.name,
                        .message = "Store definition must have a project-relative .store.rx path",
                    });
                };
            } else {
                regular[regular_pos] = input;
                regular_indices[regular_pos] = row;
                regular_pos += 1;
            }
        }

        var checked = try rx.validateModulePaths(self.gpa, regular);

        defer checked.deinit();

        if (checked.value == .diagnostic) {
            const issue = checked.value.diagnostic;

            return invalid(sources[regular_indices[issue.source_index]].path, issue.issue);
        }

        for (inputs, next) |*input, version| {
            if (!isStore(input.path)) rx.markModuleSchema(input, &version.parsed.xml.value.node);
        }
    }

    batch.* = .{ .versions = next, .packages = packages };
    self.pending = batch;

    return inputs;
}

pub fn publish(self: *Self) *Batch {
    self.change(.Publish, null);

    return self.current.?;
}

pub fn discard(self: *Self) void {
    self.change(.Discard, null);
}

/// Restores the successful batch after the inputs return to an earlier analysis revision.
pub fn restore(self: *Self, batch: *Batch) void {
    self.change(.Restore, batch);
}

fn change(self: *Self, operation: selection.Operation, previous: ?*Batch) void {
    const current = self.current;
    const pending = self.pending;
    const plan = selection.transition(operation, pending != null, current == previous);

    const next = switch (plan.next) {
        .Current => current,
        .Pending => pending,
        .Previous => previous,
    };

    if (plan.drop_pending) self.release(pending.?);
    if (plan.drop_current) if (current) |batch| self.release(batch);
    if (plan.retain) next.?.readers += 1;

    self.pending = null;
    self.current = next;
}

pub fn release(self: *Self, batch: *Batch) void {
    batch.readers -= 1;

    if (batch.readers != 0) return;
    for (batch.versions) |version| self.releaseVersion(version);

    self.gpa.free(batch.versions);
    self.gpa.destroy(batch);
}

fn releaseVersion(self: *Self, version: *Version) void {
    version.readers -= 1;

    if (version.readers != 0) return;

    self.versions -= 1;
    self.capacity -= version.capacity;

    version.parsed.xml.deinit();
    self.gpa.destroy(version);
}

fn parse(self: *Self, source: rx.TextSource) !*Version {
    var parsed = try rx.parseIndexedXml(self.gpa, source.source);

    errdefer parsed.xml.deinit();

    if (parsed.xml.value == .diagnostic) return invalid(source.path, parsed.xml.value.diagnostic);

    const path = try parsed.xml.arena.allocator().dupe(u8, source.path);
    const version = try self.gpa.create(Version);

    version.* = .{ .path = path, .parsed = parsed, .capacity = parsed.xml.arena.queryCapacity() };
    self.versions += 1;
    self.capacity += version.capacity;

    return version;
}

fn invalid(path: []const u8, issue: rx.Diagnostic) error{InvalidParserModule} {
    std.debug.print("{s}: {s}\n", .{ path, issue.message });

    return error.InvalidParserModule;
}

fn view(version: *const Version, source: rx.TextSource, schema: bool) rx.ModuleSource {
    const node = &version.parsed.xml.value.node;
    var input: rx.ModuleSource = .{ .path = source.path, .node = node.*, .references = version.parsed.references, .packages = source.packages };

    if (schema) rx.markModuleSchema(&input, node);

    return input;
}
