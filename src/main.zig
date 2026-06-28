const std = @import("std");
const App = @import("App.zig");
const signal = @import("signal.zig");
const ansi = @import("ansi.zig");

pub fn main(process: std.process.Init) !void {
    ansi.init();
    signal.init();
    const io = process.io;
    var buf: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const stdout = &stdout_file_writer.interface;

    var app = App.App.init(process, stdout) catch |err| switch (err) {
        error.HelpShown, error.ListShown => return,
        else => return err,
    };
    try app.run();
}
