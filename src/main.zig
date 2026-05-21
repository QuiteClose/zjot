const std = @import("std");
const zjot = @import("zjot");

var out_buf: [4096]u8 = undefined;
var err_buf: [256]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var args_iter = std.process.Args.Iterator.init(init.args);
    var mode: enum { html, ast } = .html;
    var sourcepos = false;
    var file_path: ?[]const u8 = null;
    var skip_first = true;

    while (args_iter.next()) |arg| {
        if (skip_first) { skip_first = false; continue; }
        if (std.mem.eql(u8, arg, "--ast")) {
            mode = .ast;
        } else if (std.mem.eql(u8, arg, "--sourcepos")) {
            sourcepos = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(io);
            return;
        } else if (arg.len > 0 and arg[0] == '-') {
            var w = std.Io.File.stderr().writer(io, &err_buf);
            try w.interface.print("zjot: unknown option: {s}\n", .{arg});
            try w.interface.flush();
            std.process.exit(1);
        } else {
            file_path = try a.dupe(u8, arg);
        }
    }

    const input = if (file_path) |path|
        try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, a, .limited(10 * 1024 * 1024))
    else blk: {
        var stdin_buf: [4096]u8 = undefined;
        var r = std.Io.File.stdin().reader(io, &stdin_buf);
        break :blk try r.interface.allocRemaining(a, .limited(10 * 1024 * 1024));
    };
    defer a.free(input);

    const output = switch (mode) {
        .html => try zjot.toHtml(a, input),
        .ast => try zjot.toAstOpts(a, input, sourcepos),
    };
    defer a.free(output);

    var w = std.Io.File.stdout().writer(io, &out_buf);
    try w.interface.writeAll(output);
    try w.interface.flush();
}

fn printUsage(io: std.Io) !void {
    var w = std.Io.File.stdout().writer(io, &out_buf);
    try w.interface.writeAll(
        \\Usage: zjot [OPTIONS] [FILE]
        \\
        \\Parse Djot markup and produce output.
        \\
        \\If FILE is omitted, reads from stdin.
        \\
        \\Options:
        \\  --ast         Output AST instead of HTML
        \\  --sourcepos   Include source positions in AST output
        \\  -h, --help    Show this help message
        \\
    );
    try w.interface.flush();
}
