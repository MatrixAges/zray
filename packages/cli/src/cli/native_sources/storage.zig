const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const abi = @import("native_resource_abi").layouts.@"zig:native_resource_host";
pub const Error = error{NativeResourceFailure};
pub const Kind = enum { zig, asset };
pub const File = struct { path: []const u8, kind: Kind, sha256: []const u8, referenced_from: ?[]const u8 };
pub const Include = struct { source: []const u8, destination: []const u8 };
pub const Source = struct { path: []const u8, kind: Kind, bytes: [:0]const u8, referenced_from: ?[]const u8 };

pub const Options = struct {
    name: []const u8,
    path: ?[]const u8,
    header: ?[]const u8,
    bundle_files: []const []const u8,
    include_paths: []const []const u8,
};

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: []const u8,
    project_root: []const u8,
    options: Options,
    inputs: ?*Inputs,
    failure: ?anyerror = null,
    entry: ?[]const u8 = null,
    root: []const u8 = undefined,
    canonical_root: []const u8 = undefined,
    output_root: []const u8 = undefined,
    physical_output: ?[]const u8 = null,
    sources: std.ArrayList(Source) = .empty,
    bytes: [:0]const u8 = undefined,
    destination: []const u8 = undefined,
    include_paths: [][]const u8 = &.{},
    relocations: std.ArrayList(Include) = .empty,
    include_target: abi.IncludeTarget = undefined,
    files: []File = &.{},
    pub fn get(handle: *anyopaque) *Context {
        return @ptrCast(@alignCast(handle));
    }
    pub fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.NativeResourceFailure;
    }
};
