const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const html = @import("html.zig");
const ast = @import("ast.zig");
const Node = @import("node.zig").Node;

pub fn toHtml(a: Allocator, input: []const u8) ![]const u8 {
    var shared = Parser.SharedState{};
    var parser = Parser.init(a, input, &shared);
    const doc = try parser.parseDoc();
    var out: std.ArrayList(u8) = .{};
    try html.renderNode(a, &out, doc);
    return out.toOwnedSlice(a);
}

pub fn toAst(a: Allocator, input: []const u8) ![]const u8 {
    return toAstOpts(a, input, false);
}

pub fn toAstOpts(a: Allocator, input: []const u8, sourcepos: bool) ![]const u8 {
    var shared = Parser.SharedState{};
    var parser = Parser.init(a, input, &shared);
    parser.track_pos = sourcepos;
    const doc = try parser.parseDoc();
    var out: std.ArrayList(u8) = .{};
    try ast.renderAstNode(a, &out, doc, 0, true);
    return out.toOwnedSlice(a);
}

test {
    _ = @import("test_runner.zig");
}
