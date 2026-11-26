const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;

inputs: *Inputs,
previous_backend: []const []const u8,
backend_owner: *std.heap.ArenaAllocator,
parse_cache: ?*@import("compiler").project.ParseCache,
backend_paths: ?[]const []const u8 = null,
