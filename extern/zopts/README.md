# Command Line parsing with ZOpts

ZOpts is a zig library for parsing commandline flags. It's primary goal is to be
easy to use without relying on too much magic (ie. there's no DSL, the API
consists solely of discoverable functions). Additionally, it leans on Zig's
static typing to aid with flag definitions.

## Features

* Declarative API makes it clear which options are defined before parsing
* Supports boolean, string, and positional type arguments 
* Bind bool, []const u8, int, and enum variables directly to an argument
* Test for the presence of a flag by binding an optional
* Default values are specified by initializing your variable
* Specialized help/usage generation for your program
* Support subcommands by binding an enum to a positional
 
## Synopsis

Basic setup & use:

    const std = @import("std");
    const ZOpts = @import("zopts");
    
    pub fn main() !void {
        var opts = ZOpts.init(std.heap.page_allocator);
        defer opts.deinit();
        
        // Define flags/options here...
        
        opts.parseOrDie();
    }

Declaring a boolean flag that defaults to false:

    var verbose: bool = false;
    try opts.flag(&verbose, .{ name = "verbose" });
    
Declaring a string that defaults to "today":

    var day: []const u8 = "today";
    try opts.flag(&day, .{ name = "day" });
    
Declaring a string that must be an enum, defaulting to "blue". Parsing will fail
if something other than Red, Green, or Blue is supplied on the commandline
(ignoring case):

    var color_choice: enum{Red,Green,Blue} = .Blue;
    try opts.flag(&color_choice, .{ .name = "color" });
    
Declaring a number. Parsing will fail if the supplied number can't be
represented properly (eg., more bits required, or a negative value to an
unsigned):

    var num_hats: u32 = 0;
    var distance: i8 = 0;
    
    try opts.flag(&num_hats, .{ .name = "num-hats" });
    try opts.flag(&distance, .{ .name = "distance" });
    
Sometimes you don't have a suitable default, and need to detect if an option was
omitted on the commandline. You can do this by making one of the above types
optional:

    var first_name: ?[]const u8 = null;
    var age: ?u8 = null;
    
    try opts.flag(&first_name, .{ .name = "first-name" });
    try opts.flag(&age, .{ .name = "age" });

    opts.parseOrDie();

    if (first_name) |n| {
        // User passed in a first name
    }
    
    if (age) |n| {
        // User passed in an age
    }

Declaring positional arguments:

    var pattern: []const u8 = "";
    var count: u32 = 0;
    
    try opts.arg(&pattern, .{});
    try opts.arg(&count, .{});

Capturing any extra positional arguments:

    var extra: [][]const u8 = undefined;
    try opts.extra(&extra, .{});

To provide extra information for the help string, there's additional
fields you can pass to the `.flag(...)` function (`.short`,
`.placeholder`, and `.description`), as well as to `.arg(...)` and
`.extra(...)` (`.placeholder` and `.description`). These give more
context when printing usage information.

    var name: []const u8 = "";
    var file: []const u8 = "";
    var colors: [][]const u8 = undefined;
    
    try opts.flag(&name, .{ .name = "name", .short = 'n', .placeholder = "NAME", .description = "Name of the user running a query" });
    try opts.arg(&file, .{ .placeholder = "INPUT", .description = "File name containing data" });
    try opts.extra(&colors, .{ .placeholder = "[COLOR]", .description = "List of color names" });

## Case example "grep"

Here's the help string for a fictional implementation of grep:

    ~/code/zig/grep $ grep -h
    usage: grep [OPTIONS] PATTERN [FILE]...
    An example "grep" program illustrating various option types as a means to show
    real usage of the ZOpts package.
    
    OPTIONS
       -C, --context=LINES       Number of lines of context to include before and
                                 after a match (default is 3).
       -i, --ignore-case         Enable case insensitive search.
           --color=(On|Off|Auto) Colorize the output (default is Auto).
       -h, --help                Display this help message.
    
    ARGS
       PATTERN                   Pattern to search on.
       [FILE]                    Files to search. Omit for stdin.

This can be implemented w/ ZOpts as follows:

    const Config = struct {
        context: u32 = 3,
        ignore_case: bool = false,
        color: enum { On, Off, Auto } = .Auto,

        pattern: ?[]const u8 = null, // Optional, because we need to see if it was specified
        files: [][]const u8 = undefined,
    };

    fn parseOpts(allocator: *std.mem.Allocator) !struct { cfg: Config, data: [][]const u8 } {
        var zopts = ZOpts.init(allocator);
        defer zopts.deinit();

        var cfg = Config{};

        // Define general information about the program
        
        zopts.name("grep");
        zopts.summary(
            \\An example "grep" program illustrating various option types as
            \\a means to show real usage of the ZOpts package.
        );

        // Declare any flags, providing names, descriptions, and binding to variables

        try zopts.flag(&cfg.context, .{ .name = "context", .short = 'C', .placeholder = "LINES", .description = "Number of lines of context to include before and after a match (default is 3)." });
        try zopts.flag(&cfg.ignore_case,, .{ .name = "ignore-case", .short ='i', .description = "Enable case insensitive search." });
        try zopts.flag(&cfg.color, .{ .name = "color", .description = "Colorize the output (default is Auto)." });

        var show_help = false;
        try zopts.flag(&show_help, .{ .name = "help", .short = 'h', .description = "Display this help message." });

        // Declare positional arguments, if any
        
        try zopts.arg(&cfg.pattern, .{ .placeholder = "PATTERN", .description = "Pattern to search on." });
        try zopts.extra(&cfg.files, .{ .placeholder = "[FILE]", .description = "Files to search. Omit for stdin." });

        // Perform the parse; this will fill out the variables, or, in the case of 
        // a parse error, print help information and exit the program.

        zopts.parseOrDie();

        if (show_help) {
            zopts.printHelpAndDie();
        }
        
        // Require a pattern from the user
        if ( cfg.pattern == null ) {
            zopts.setError("No pattern specified!");
            zopts.printHelpAndDie();
        }

        // Any string data that was pulled in (for `cfg.pattern` and `cfg.files`)
        // is allocated on the heap and owned by `zopts`. Therefore, it will be
        // cleaned up by the call to `zopts.deinit()`. We want to pass this data
        // back to the caller, so we use `zopts.toOwnedSlice()` to extricate it.
        //
        // (if zopts had been declared in `main` this wouldn't be needed)
        var result = .{
            .cfg = cfg,
            .data = try zopts.toOwnedSlice(),
        };

        return result;
    }
    
    pub fn main() !void {
        var opts = try parseOpts(std.heap.page_allocator);
        defer {
            for (opts.data) |ptr| {
                std.heap.page_allocator.free(ptr);
            }
            std.heap.page_allocator.free(opts.data);
        }
        
        var cfg = opts.cfg;
        
        // Go about your business
    }
