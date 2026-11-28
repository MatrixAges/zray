const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const analysis = @import("rx_analysis");
const Text = @import("../../sources/text.zig");
const state = @import("state.zig");
const State = state.State;
const Error = state.effects.Error;
const abi = @import("cli_abi");
const XmlValidation = abi.native.@"zig:rx_collection_host".XmlValidation;
const GatewayRoutes = abi.layouts.@"zig:rx_collection_host".GatewayRoutes;

pub fn collectZxReferences(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const file = &self.file;

    self.documents.items[file.row] = .{ .zx = .{ .path = file.path, .source = file.text.bytes } };

    const parsed = self.cache.getModule(file.text.bytes, file.absolute) catch |err| return self.failure.save(err);

    if (parsed.diagnostic() != null) return;

    self.startCollector(null);
    analysis.project.source_graph.references.collectZx(&self.collector, parsed) catch |err| return self.failure.save(err);
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
    self.documents.items[file.row] = .{ .xml = .{ .module = file.module, .bytes = file.text.bytes } };

    self.startCollector(scope);

    return true;
}

pub fn validateCollectionXml(handle: *const anyopaque) Error!XmlValidation {
    const self = State.get(handle);

    self.checked = rx.validateSource(self.backing, &self.file.module) catch |err| return self.failure.save(err);

    const checked = &self.checked.?;

    if (checked.value == .diagnostic) {
        _ = try diagnose(self, checked.value.diagnostic);

        return .Invalid;
    }

    const data = checked.value.data;

    if (data == .gateway and (data.gateway.attributes.protocol orelse .http) == .http) return .HttpGateway;

    return .Valid;
}

pub fn prepareCollectionGateway(allocator: std.mem.Allocator, handle: *const anyopaque) (Error || std.mem.Allocator.Error)!?*const GatewayRoutes {
    const self = State.get(handle);
    const file = &self.file;
    const attrs = self.checked.?.value.data.gateway.attributes;

    self.result.gateway_analysis = analysis.gateway.analyze(self.backing, .{
        .owner = file.path,
        .node = file.module.node,
        .validated_attributes = attrs,
    }) catch |err| return self.failure.save(err);

    const value = &self.result.gateway_analysis.?.value;

    if (value.* != .diagnostic) {
        const definition = &value.definition;
        const route_services = try allocator.alloc([]const u8, definition.routes.len);

        for (definition.routes, route_services) |route, *service| service.* = route.service;

        const routes = try allocator.create(GatewayRoutes);

        routes.* = .{ .route_services = route_services, .service_routes = definition.service_routes };

        return routes;
    }

    const issue = value.diagnostic;

    self.options.writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ issue.path, issue.location.line, issue.location.column, issue.code, issue.message }) catch |err| return self.failure.save(err);

    return null;
}

pub fn collectGatewayService(handle: *const anyopaque, path: []const u8) Error!void {
    const self = State.get(handle);

    self.collector.enqueue(path) catch |err| return self.failure.save(err);
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
