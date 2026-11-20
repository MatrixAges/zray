const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
pub const Error = error{NativeResourceFailure};
pub const Kind = enum { zig, asset };
pub const Reference = struct { path: []const u8, kind: Kind };
pub const File = struct { path: []const u8, kind: Kind, sha256: []const u8, referenced_from: ?[]const u8 };
pub const Include = struct { source: []const u8, destination: []const u8 };
pub const Pending = struct { path: []const u8, kind: Kind, from: ?[]const u8 };
pub const Seen = struct { index: usize, parsed: bool };
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
    pending: std.ArrayList(Pending) = .empty,
    sources: std.ArrayList(Source) = .empty,
    seen: std.StringHashMapUnmanaged(Seen) = .empty,
    current: Pending = undefined,
    relative: []const u8 = undefined,
    previous: ?*Seen = null,
    bytes: [:0]const u8 = undefined,
    ast: ?std.zig.Ast = null,
    node_index: usize = 0,
    builtin: struct {
        name: []const u8,
        count: usize,
        parameter: ?std.zig.Ast.Node.Index,
    } = undefined,
    references: std.ArrayList(Reference) = .empty,
    destination: []const u8 = undefined,
    include_paths: [][]const u8 = &.{},
    relocations: std.ArrayList(Include) = .empty,
    include_absolute: []const u8 = undefined,
    include_relative: []const u8 = undefined,
    files: []File = &.{},
    pub fn get(handle: *const anyopaque) *Context {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    pub fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.NativeResourceFailure;
    }
};
