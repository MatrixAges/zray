pub const Origin = enum { Cached, Ahead, Analyze };

pub fn choose(cached: bool, ahead: bool) Origin {
    return if (cached) .Cached else if (ahead) .Ahead else .Analyze;
}
