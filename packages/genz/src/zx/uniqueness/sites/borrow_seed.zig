const std = @import("std");
const Seed = @import("seed.zig");
const Role = @import("../order/seed.zig").Role;
const none = @import("../order/seed.zig").none;
const Site = Seed.Site;

const Candidate = struct {
    site: usize,
    node: u32,
    start: u32,
    finish: u32,
    fn later(_: void, left: Candidate, right: Candidate) bool {
        if (left.finish != right.finish) return left.finish > right.finish;

        return left.start < right.start;
    }
};

pub fn normalize(allocator: std.mem.Allocator, source: *Seed) std.mem.Allocator.Error!void {
    var candidates: std.ArrayList(Candidate) = .empty;

    defer candidates.deinit(allocator);

    for (source.sites, 0..) |site, index| {
        if (!eligible(source, site)) continue;

        try candidates.append(allocator, .{
            .site = index,
            .node = site.parent,
            .start = source.order.timeAt(site.parent),
            .finish = source.order.finishAt(site.parent),
        });
    }

    if (candidates.items.len == 0) return;

    std.mem.sort(Candidate, candidates.items, {}, Candidate.later);

    const ends = try allocator.alloc(u32, source.expressions.call_functions.len);

    defer allocator.free(ends);
    @memset(ends, none);

    var previous: u32 = none;

    for (candidates.items) |candidate| {
        if (previous == candidate.node) continue;

        ends[source.expressions.payloads[candidate.node]] = completion(source, ends, candidate.node);
        previous = candidate.node;
    }

    var serial = source.order.edgeCount();

    for (candidates.items) |candidate| {
        const boundary = ends[source.expressions.payloads[candidate.node]];

        if (boundary == none) continue;

        const site = &source.sites[candidate.site];

        site.role = .observe;
        site.parent = boundary;
        site.edge = std.math.cast(u32, serial) orelse return error.OutOfMemory;
        serial += 1;
    }
}

fn completion(source: *const Seed, ends: []const u32, node: u32) u32 {
    const root = source.nodeRoot(@fromBackingInt(node));
    const repeated = source.order.loopAt(node);
    var latest = node;

    for (source.sites[source.first[root]..source.first[root + 1]]) |site| {
        const boundary = if (site.parent == none) @backingInt(site.top) else site.parent;

        if (source.order.loopAt(boundary) != repeated) return none;

        const end = if (observes(source, site)) boundary else if (eligible(source, site)) ends[source.expressions.payloads[boundary]] else none;

        if (end == none) return none;
        if (source.order.finishAt(end) > source.order.finishAt(latest)) latest = end;
    }

    return latest;
}

fn borrowOnly(source: *const Seed, callee: usize) bool {
    return source.summaries.return_only[callee] and source.summaries.held[callee].len == source.summaries.written[callee].len and
        std.mem.indexOfScalar(bool, source.summaries.written[callee], true) == null;
}

fn known(source: *const Seed, site: Site, callee: usize) bool {
    const first = @as(i64, site.lo) + site.delta;
    const end = @as(i64, site.hi) + site.delta;

    return first >= 0 and end <= @min(source.summaries.held[callee].len, source.summaries.written[callee].len);
}

fn resolved(source: *const Seed, site: Site) Role {
    if (site.role != .argument) return site.role;

    const callee = @backingInt(source.expressions.get(@fromBackingInt(site.parent)).value.call.function);
    const held = source.summaries.held[callee];
    const written = source.summaries.written[callee];
    const result = source.nodeRoot(@fromBackingInt(site.parent));

    if (known(source, site, callee) and borrowOnly(source, callee) and source.first[result] == source.first[result + 1]) return .observe;

    const count = @min(held.len, written.len);
    var consumed = true;
    var observed = true;

    for (held[0..count], written[0..count]) |retained, updated| {
        consumed = consumed and (retained or updated);
        observed = observed and !retained and !updated;
    }

    if (count == 0 or consumed) return .use;
    if (observed and known(source, site, callee)) return .observe;

    return .argument;
}

fn eligible(source: *const Seed, site: Site) bool {
    if (site.role != .argument) return false;

    const callee = @backingInt(source.expressions.get(@fromBackingInt(site.parent)).value.call.function);

    if (!source.summaries.return_only[callee] or !known(source, site, callee)) return false;

    const first: usize = @intCast(@as(i64, site.lo) + site.delta);
    const end: usize = @intCast(@as(i64, site.hi) + site.delta);

    return std.mem.indexOfScalar(bool, source.summaries.written[callee][first..end], true) == null and
        std.mem.indexOfScalar(bool, source.summaries.held[callee][first..end], true) != null;
}

fn observes(source: *const Seed, site: Site) bool {
    const role = resolved(source, site);

    if (role != .observe and role != .argument) return false;
    if (site.parent == none) return role == .observe;

    const parent = source.expressions.get(@fromBackingInt(site.parent)).value;

    if (parent != .call) return role == .observe;

    const callee = @backingInt(parent.call.function);

    if (!source.summaries.return_only[callee] or !known(source, site, callee)) return false;
    if (role == .observe and borrowOnly(source, callee)) return true;

    const first: usize = @intCast(@as(i64, site.lo) + site.delta);
    const end: usize = @intCast(@as(i64, site.hi) + site.delta);

    return std.mem.indexOfScalar(bool, source.summaries.held[callee][first..end], true) == null and
        std.mem.indexOfScalar(bool, source.summaries.written[callee][first..end], true) == null;
}
