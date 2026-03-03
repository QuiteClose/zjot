const std = @import("std");
const zjot = @import("zjot");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);

    var mode: enum { html, ast } = .html;
    var sourcepos = false;
    var file_path: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--ast")) {
            mode = .ast;
        } else if (std.mem.eql(u8, arg, "--sourcepos")) {
            sourcepos = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage();
            return;
        } else if (arg.len > 0 and arg[0] == '-') {
            const stderr = std.fs.File.stderr().writer();
            try stderr.print("zjot: unknown option: {s}\n", .{arg});
            std.process.exit(1);
        } else {
            file_path = arg;
        }
    }

    const input = if (file_path) |path|
        try std.fs.cwd().readFileAlloc(a, path, 10 * 1024 * 1024)
    else
        try std.fs.File.stdin().readToEndAlloc(a, 10 * 1024 * 1024);
    defer a.free(input);

    const output = switch (mode) {
        .html => try zjot.toHtml(a, input),
        .ast => try zjot.toAstOpts(a, input, sourcepos),
    };
    defer a.free(output);

    const stdout = std.fs.File.stdout().writer();
    try stdout.writeAll(output);
}

fn printUsage() !void {
    const stdout = std.fs.File.stdout().writer();
    try stdout.writeAll(
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
}
