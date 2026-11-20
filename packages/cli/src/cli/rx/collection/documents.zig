const compiler = @import("compiler");
const rx = @import("rx");
const analysis = @import("rx_analysis");
const zx = @import("zx");
const Text = @import("../../sources/text.zig");
const state = @import("state.zig");
const State = state.State;
const Error = state.effects.Error;

pub fn openCollectionZxHeader(handle: *const anyopaque) Error!u64 {
    const self = State.get(handle);
    const file = &self.file;
    const parsed = self.cache.getModule(file.text.bytes, file.absolute) catch |err| return self.failure.save(err);

    file.parsed = parsed;

    if (parsed.diagnostic() != null) return 0;

    self.startCollector(null);

    return switch (parsed.*) {
        .native => |*result| (zx.syntax.header.Native{ .program = result.value.parsed.ast }).importCount(),
        .indexed => |*result| if (compiler.project.ParseCache.indexed_enabled) result.header().importCount() else unreachable,
    };
}

pub fn collectZxHeaderImport(handle: *const anyopaque, row: u64) Error!void {
    const self = State.get(handle);
    const index: usize = @intCast(row);

    const imported = switch (self.file.parsed.*) {
        .native => |*result| (zx.syntax.header.Native{ .program = result.value.parsed.ast }).importAt(index),
        .indexed => |*result| if (compiler.project.ParseCache.indexed_enabled) result.header().importAt(index) else unreachable,
    };

    self.collector.import(imported.path, .{ .offset = imported.span.start, .line = 1, .column = 1 }, .dependency, null) catch |err| return self.failure.save(err);
}

pub fn recordCollectionZx(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const file = &self.file;

    self.functions.append(self.allocator, .{ .path = file.path, .source = file.text.bytes }) catch |err| return self.failure.save(err);
}

pub fn parseCollectionXml(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const file = &self.file;
    const document = Text.parseRx(self.allocator, file.documents, file.absolute, file.text) catch |err| return self.failure.save(err);
    const parsed = document.xml;

    if (parsed.value == .diagnostic) return diagnose(self, parsed.value.diagnostic);

    const scope = compiler.project.ImportScope.init(self.project.package_scopes, file.absolute);
    const packages = scope.dependencies(self.project.packages);

    file.module = .{ .path = file.path, .node = parsed.value.node, .packages = packages, .references = document.references };

    self.startCollector(scope);

    return true;
}

pub fn validateCollectionXml(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    self.checked = rx.validateSource(self.backing, &self.file.module) catch |err| return self.failure.save(err);

    const checked = &self.checked.?;

    if (checked.value == .diagnostic) return diagnose(self, checked.value.diagnostic);

    return true;
}

pub fn recordCollectionModule(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const file = &self.file;
    const module = file.module;

    self.sources.append(self.allocator, .{ .path = file.path, .source = file.text.bytes, .packages = module.packages }) catch |err| return self.failure.save(err);
    self.modules.append(self.allocator, module) catch |err| return self.failure.save(err);
}

pub fn recordCollectionStore(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.stores.append(self.allocator, self.file.module) catch |err| return self.failure.save(err);
}

pub fn recordCollectionGateway(handle: *const anyopaque) bool {
    const self = State.get(handle);
    const file = &self.file;

    self.gateway = .{ .path = file.path, .node = file.module.node };

    return (self.checked.?.value.data.gateway.attributes.protocol orelse .http) == .http;
}

pub fn prepareCollectionGateway(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const file = &self.file;
    const attrs = self.checked.?.value.data.gateway.attributes;

    self.result.gateway_analysis = analysis.gateway.analyze(self.backing, .{
        .owner = file.path,
        .node = file.module.node,
        .validated_attributes = attrs,
    }) catch |err| return self.failure.save(err);

    const value = &self.result.gateway_analysis.?.value;

    if (value.* != .diagnostic) return true;

    const issue = value.diagnostic;

    self.options.writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ issue.path, issue.location.line, issue.location.column, issue.code, issue.message }) catch |err| return self.failure.save(err);

    return false;
}

pub fn collectionGatewayServices(handle: *const anyopaque) u64 {
    return State.get(handle).result.gateway_analysis.?.value.definition.service_routes.len;
}

pub fn collectGatewayService(handle: *const anyopaque, row: u64) Error!void {
    const self = State.get(handle);
    const definition = &self.result.gateway_analysis.?.value.definition;
    const index = definition.service_routes[@intCast(row)];
    const route = &definition.routes[index];

    self.collector.local(route.service, route.location, .dependency) catch |err| return self.failure.save(err);
}

pub fn collectXmlReferences(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    analysis.project.source_graph.references.collect(&self.collector, self.file.module) catch |err| {
        if (err == error.InvalidSourceGraph) return false;

        return self.failure.save(err);
    };

    return true;
}

fn diagnose(self: *State, issue: rx.Diagnostic) Error!bool {
    self.options.writer.print("{s}:{d}:{d}: {t}: {s}\n", .{ self.file.path, issue.location.line, issue.location.column, issue.code, issue.message }) catch |err| return self.failure.save(err);

    return false;
}
