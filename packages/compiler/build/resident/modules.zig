const std = @import("std");
const rx = @import("rx");
const bytes = @import("compiler").bytes;
const Self = @This();

const Version = struct {
    path: []const u8,
    parsed: rx.IndexedXml,
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

/// Borrows unchanged XML and stages new versions until an analysis publishes them. Sources are sorted by path.
pub fn prepare(self: *Self, owner: std.mem.Allocator, sources: []const rx.TextSource, packages: [32]u8) ![]const rx.ModuleSource {
    std.debug.assert(self.pending == null);

    const inputs = try owner.alloc(rx.ModuleSource, sources.len);
    const before = if (self.current) |batch| batch.versions else &.{};

    if (self.current) |batch| {
        if (before.len == sources.len and bytes.equal(&batch.packages, &packages) and same(before, sources)) {
            for (before, inputs, sources) |version, *input, source| input.* = view(version, source, true);

            self.reused += before.len;

            return inputs;
        }
    }

    const batch = try self.gpa.create(Batch);

    errdefer self.gpa.destroy(batch);

    const next = try self.gpa.alloc(*Version, sources.len);

    errdefer self.gpa.free(next);

    var initialized: usize = 0;
    var first: usize = 0;

    errdefer for (next[0..initialized]) |version| self.releaseVersion(version);

    for (sources, inputs, next) |source, *input, *version| {
        const old = find(before, &first, source.path);
        const reused = old != null and bytes.equal(old.?.parsed.xml.source, source.source);

        if (reused) {
            version.* = old.?;
            version.*.readers += 1;
            self.reused += 1;
        } else {
            self.parsed += 1;
            version.* = try self.parse(source);
        }

        initialized += 1;
        input.* = view(version.*, source, reused);
    }

    var checked = try rx.validateModulePaths(self.gpa, inputs);

    defer checked.deinit();

    if (checked.value == .diagnostic) {
        const issue = checked.value.diagnostic;

        return invalid(sources[issue.source_index].path, issue.issue);
    }

    for (inputs, next) |*input, version| rx.markModuleSchema(input, &version.parsed.xml.value.node);

    batch.* = .{ .versions = next, .packages = packages };
    self.pending = batch;

    return inputs;
}

pub fn publish(self: *Self) *Batch {
    if (self.pending) |batch| {
        if (self.current) |old| self.release(old);

        self.current = batch;
        self.pending = null;
    }

    const batch = self.current.?;

    batch.readers += 1;

    return batch;
}

pub fn discard(self: *Self) void {
    if (self.pending) |batch| self.release(batch);

    self.pending = null;
}

/// Restores the successful batch after the inputs return to an earlier analysis revision.
pub fn restore(self: *Self, batch: *Batch) void {
    self.discard();

    if (self.current == batch) return;
    if (self.current) |current| self.release(current);

    batch.readers += 1;
    self.current = batch;
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
    self.capacity -= version.parsed.xml.arena.queryCapacity();

    version.parsed.xml.deinit();
    self.gpa.destroy(version);
}

fn parse(self: *Self, source: rx.TextSource) !*Version {
    var parsed = try rx.parseIndexedXml(self.gpa, source.source);

    errdefer parsed.xml.deinit();

    if (parsed.xml.value == .diagnostic) return invalid(source.path, parsed.xml.value.diagnostic);

    const path = try parsed.xml.arena.allocator().dupe(u8, source.path);
    const version = try self.gpa.create(Version);

    version.* = .{ .path = path, .parsed = parsed };
    self.versions += 1;
    self.capacity += parsed.xml.arena.queryCapacity();

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

fn find(versions: []const *Version, first: *usize, path: []const u8) ?*Version {
    while (first.* < versions.len) {
        const version = versions[first.*];

        switch (std.mem.order(u8, version.path, path)) {
            .lt => first.* += 1,
            .eq => return version,
            .gt => return null,
        }
    }

    return null;
}

fn same(versions: []const *Version, sources: []const rx.TextSource) bool {
    for (versions, sources) |version, source| {
        if (!bytes.equal(version.path, source.path) or !bytes.equal(version.parsed.xml.source, source.source)) return false;
    }

    return true;
}
