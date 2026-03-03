const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn toHtml(a: Allocator, input: []const u8) Allocator.Error![]const u8 {
    _ = input;
    return a.dupe(u8, "");
}

pub fn toAst(a: Allocator, input: []const u8) Allocator.Error![]const u8 {
    return toAstOpts(a, input, false);
}

pub fn toAstOpts(a: Allocator, input: []const u8, sourcepos: bool) Allocator.Error![]const u8 {
    _ = input;
    _ = sourcepos;
    return a.dupe(u8, "");
}

test {
    _ = @import("test_runner.zig");
}
