const main = @import("main");
const execution = @import("execution");

// Standard implementations share the types of the generated calls that use them.
pub const native = struct {
    pub const @"std:child_process" = execution.native.@"std:child_process";
    pub const @"std:crypto" = main.native.@"std:crypto";
    pub const @"std:crypto/blake3" = execution.native.@"std:crypto/blake3";
    pub const @"std:fs" = execution.native.@"std:fs";
    pub const @"std:http" = main.native.@"std:http";
    pub const @"std:path" = main.native.@"std:path";
    pub const @"std:path/posix" = main.native.@"std:path/posix";
    pub const @"std:path/win32" = main.native.@"std:path/win32";
    pub const @"std:querystring" = main.native.@"std:querystring";
    pub const @"std:url" = main.native.@"std:url";
    pub const @"std:url/search_params" = main.native.@"std:url/search_params";
    pub const @"std:zlib" = main.native.@"std:zlib";
};

pub const layouts = main.layouts;
