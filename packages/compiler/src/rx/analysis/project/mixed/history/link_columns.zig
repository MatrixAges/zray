const std = @import("std");
const frontend = @import("frontend");
const memory = @import("zx").memory;
const Finished = @import("../finished.zig");
const Surface = frontend.project.artifact.source_link.Surface;
const Initializer = std.meta.Elem(@FieldType(Surface, "store_initializers"));
const little_endian = @import("builtin").target.cpu.arch.endian() == .little;

pub fn Columns(comptime Link: type) type {
    const Ports = std.meta.Child(@FieldType(Link, "ports"));
    const Exports = std.meta.Child(@FieldType(Link, "exports"));
    const Initializers = std.meta.Child(@FieldType(Link, "initializers"));
    const Members = std.meta.Child(@FieldType(Link, "members"));
    const Constants = std.meta.Child(@FieldType(Link, "constants"));

    return struct {
        left: Side,
        right: Side,
        ports: Ports,
        exports: Exports,
        initializers: Initializers,
        members: Members,
        constants: Constants,
        const Side = struct {
            exports: []const memory.NamedId,
            member_rows: frontend.project.FunctionImport.Columns,
            constant_rows: frontend.ConstantRows,
            port: std.meta.Child(@FieldType(Ports, "left")),
            initializers: std.meta.Child(@FieldType(Initializers, "left")),
            members: std.meta.Child(@FieldType(Members, "left")),
            constants: std.meta.Child(@FieldType(Constants, "left")),
            fn bind(self: *Side, surface: *const Surface, function: ?u32) void {
                self.exports = memory.borrowNamedRows("type_id", surface.exports);
                self.member_rows = frontend.project.FunctionImport.borrowColumns(surface.members);
                self.constant_rows = frontend.ConstantRows.borrow(surface.constant_exports);

                self.port = .{
                    .function = function,
                    .input_type = @backingInt(surface.input_type),
                    .output_type = @backingInt(surface.output_type),
                };

                self.initializers = .{
                    .data = std.mem.sliceAsBytes(surface.store_initializers),
                    .count = surface.store_initializers.len,
                };

                self.members = self.member_rows.bind(@TypeOf(self.members));
                self.constants = self.constant_rows.view(@TypeOf(self.constants));
            }
        };
        pub fn bind(self: *@This(), current: *const Finished, previous: *const Finished, row: usize) Link {
            const left = current.getAssumePresent(row);
            const right = previous.getAssumePresent(row);

            self.left.bind(left, current.functions[row]);
            self.right.bind(right, previous.functions[row]);

            self.ports = .{ .left = &self.left.port, .right = &self.right.port };

            self.exports = .{
                .left = @ptrCast(&self.left.exports),
                .right = @ptrCast(&self.right.exports),
                .left_count = self.left.exports.len,
                .right_count = self.right.exports.len,
                .shared = left.exports.ptr == right.exports.ptr,
            };

            self.initializers = .{
                .left = &self.left.initializers,
                .right = &self.right.initializers,
                .stride = @sizeOf(Initializer),
                .identity_offset = @offsetOf(Initializer, "identity"),
                .function_id = @offsetOf(Initializer, "function"),
                .schema_version = @offsetOf(Initializer, "schema_version"),
                .little_endian = little_endian,
                .shared = left.store_initializers.ptr == right.store_initializers.ptr,
                .identity = false,
                .function_prefix = null,
            };

            self.members = .{
                .left = &self.left.members,
                .right = &self.right.members,
                .shared = left.members.ptr == right.members.ptr,
            };

            self.constants = .{
                .left = &self.left.constants,
                .right = &self.right.constants,
                .shared = left.constant_exports.ptr == right.constant_exports.ptr,
            };

            return .{
                .ports = &self.ports,
                .exports = &self.exports,
                .initializers = &self.initializers,
                .members = &self.members,
                .constants = &self.constants,
            };
        }
    };
}
