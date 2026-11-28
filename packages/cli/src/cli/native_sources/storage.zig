const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
pub const Error = error{NativeResourceFailure};
pub const Kind = enum { zig, asset };
pub const File = struct { path: []const u8, kind: Kind, sha256: []const u8, referenced_from: ?[]const u8 };
pub const Include = struct { source: []const u8, destination: []const u8 };

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
    inputs: ?*Inputs,
    failure: ?anyerror = null,
    pub fn get(handle: *const anyopaque) *Context {
        const reference: *const *Context = @ptrCast(@alignCast(handle));

        return reference.*;
    }

    pub fn fail(self: *Context, err: anyerror) Error {
        self.failure = err;

        return error.NativeResourceFailure;
    }
};
