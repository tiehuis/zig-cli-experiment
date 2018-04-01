const std = @import("std");
const builtin = @import("builtin");

const os = std.os;
const io = std.io;
const mem = std.mem;
const Allocator = mem.Allocator;
const Buffer = std.Buffer;

const arg = @import("arg.zig");
const Args = arg.Args;
const Flag = arg.Flag;

var stderr: &io.OutStream(io.FileOutStream.Error) = undefined;
var stdout: &io.OutStream(io.FileOutStream.Error) = undefined;

const usage =
    \\usage: zig [command] [options]
    \\
    \\Commands:
    \\
    \\  build                        build project from build.zig
    \\  build-exe   [source]         create executable from source or object files
    \\  build-lib   [source]         create library from source or object files
    \\  build-obj   [source]         create object from source or assembly
    \\  run         [source]         create executable and run immediately
    \\  fmt         [source]         parse file and render in canonical zig format
    \\  translate-c [source]         convert c code to zig code
    \\  targets                      list available compilation targets
    \\  test        [source]         create and run a test build
    \\  version                      print version number and exit
    \\  zen                          print zen of zig and exit
    \\
    \\
    ;

const Command = struct {
    name: []const u8,
    exec: fn(&Allocator, []const []const u8) error!void,
};

// Workaround infallible functions
fn alwaysOk() !void {
    var always_true: bool = true;
    if (!always_true) return error.Unreachable;
}

// Workaround for undefined function error
fn cmdPlaceholder(allocator: &Allocator, args: []const []const u8) !void {
    try alwaysOk();
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var stdout_file = try std.io.getStdOut();
    var stdout_out_stream = std.io.FileOutStream.init(&stdout_file);
    stdout = &stdout_out_stream.stream;

    var stderr_file = try std.io.getStdErr();
    var stderr_out_stream = std.io.FileOutStream.init(&stderr_file);
    stderr = &stderr_out_stream.stream;

    const args = try os.argsAlloc(allocator);
    defer os.argsFree(allocator, args);

    if (args.len <= 1) {
        try stderr.write(usage);
        return;
    }

    const commands = []Command {
        Command { .name = "build",       .exec = cmdBuild },
        Command { .name = "build-exe",   .exec = cmdPlaceholder  },
        Command { .name = "build-lib",   .exec = cmdPlaceholder  },
        Command { .name = "build-obj",   .exec = cmdPlaceholder  },
        Command { .name = "fmt",         .exec = cmdFmt     },
        Command { .name = "help",        .exec = cmdHelp    },
        Command { .name = "run",         .exec = cmdPlaceholder  },
        Command { .name = "translate-c", .exec = cmdPlaceholder  },
        Command { .name = "targets",     .exec = cmdTargets },
        Command { .name = "test",        .exec = cmdPlaceholder  },
        Command { .name = "version",     .exec = cmdVersion },
        Command { .name = "zen",         .exec = cmdZen     },

        // non user facing commands
        Command { .name = "BUILD_INFO",  .exec = cmdBuildInfo },
    };

    inline for (commands) |command| {
        if (mem.eql(u8, command.name, args[1])) {
            try command.exec(allocator, args[2..]);
            return;
        }
    }

    try stderr.print("unknown command: {}\n\n", args[1]);
    try stderr.write(usage);
}

// build ///////////////////////////////////////////////////////////////////////////////////////////

const usage_build =
    \\usage: zig build <options>
    \\
    \\   Project-specific options become available when the build file is found.
    \\
    \\General Options:
    \\   --help                 Print this help and exit
    \\   --init                 Generate a build.zig template
    \\   --build-file [file]    Override path to build.zig
    \\   --cache-dir [path]     Override path to cache directory
    \\   --verbose              Print commands before executing them
    \\   --prefix [path]        Override default install prefix
    \\
    \\Advanced Options:"
    \\   --build-file [file]    Override path to build.zig
    \\   --cache-dir [path]     Override path to cache directory
    \\   --verbose-tokenize     Enable compiler debug output for tokenization
    \\   --verbose-ast          Enable compiler debug output for parsing into an AST
    \\   --verbose-link         Enable compiler debug output for linking
    \\   --verbose-ir           Enable compiler debug output for Zig IR
    \\   --verbose-llvm-ir      Enable compiler debug output for LLVM IR
    \\   --verbose-cimport      Enable compiler debug output for C imports
    \\
    \\
    ;

const args_build_spec = []Flag {
    Flag.Bool("help"),
    Flag.Bool("init"),
    Flag.Arg1("build-file"),
    Flag.Arg1("cache-dir"),
    Flag.Bool("verbose"),
    Flag.Arg1("prefix"),
    Flag.Arg1("build-file"),
    Flag.Arg1("cache-dir"),
    Flag.Bool("verbose-tokenize"),
    Flag.Bool("verbose-ast"),
    Flag.Bool("verbose-link"),
    Flag.Bool("verbose-ir"),
    Flag.Bool("verbose-llvm-ir"),
    Flag.Bool("verbose-cimport"),
};

const missing_build_file =
    \\No 'build.zig' file found.
    \\Initialize a 'build.zig' template file with `zig build --init`,
    \\or build an executable directly with `zig build-exe $FILENAME.zig`.
    \\See: `zig build --help` or `zig help` for more options.
    \\
    \\
    ;

fn cmdBuild(allocator: &Allocator, args: []const []const u8) !void {
    var flags = try Args.parse(allocator, args_build_spec, args);
    defer flags.deinit();

    if (flags.present("help")) {
        try stderr.write(usage_build);
        return;
    }

    if (flags.present("init")) {
        var build_file_abs = try Buffer.init(allocator, "./"); // TODO
        defer build_file_abs.deinit();

        var special_dir = try Buffer.init(allocator, "/std/special"); // TODO
        defer special_dir.deinit();

        try special_dir.append("/");
        try special_dir.append("build_file_template.zig");

        if (os.copyFile(allocator, special_dir.toSliceConst(), build_file_abs.toSliceConst())) |_| {
            try stderr.write("Wrote build.zig template\n");
        } else |err| {
            try stderr.print("Unable to write build.zig template: {}\n", err);
        }

        return;
    }

    // if (!os.fileExists("build.zig")) {
    //     try stderr.write(missing_build_file);
    //     return;
    // }

    // init_all_targets()

    // construct exec command and pass through arguments

    // find cache dir

    // create codegen package and spawn process returning its exit status.

    // Can we can call the build-runner directly from zig without a separate process?
}

// fmt /////////////////////////////////////////////////////////////////////////////////////////////

const usage_fmt =
    \\usage: zig fmt [file]...
    \\
    \\Options:
    \\   --help                 Print this help and exit
    \\
    \\
    ;

const args_fmt_spec = []Flag {
    Flag.Bool("help"),
};

fn cmdFmt(allocator: &Allocator, args: []const []const u8) !void {
    var flags = try Args.parse(allocator, args_build_spec, args);
    defer flags.deinit();

    if (flags.present("help")) {
        try stderr.write(usage_fmt);
        return;
    }
}

// targets /////////////////////////////////////////////////////////////////////////////////////////

fn cmdTargets(allocator: &Allocator, args: []const []const u8) !void {
    // TODO: Need field access by name to get the enum value.
    // stdout.write("Architectures:\n");
    // for (@fieldsOf(builtin.Arch)) |arch| {
    //     const native_str = ""; // if (builtin.arch == arch) " (native) " else "";
    //     stdout.print("   {}{}\n", native_str, arch.name);
    // }

    // stdout.write("Operating Systems:\n");
    // for (builtin.Os) |os| {
    //     const native_str = ""; // if (builtin.os == os) " (native) " else "";
    //     stdout.print("   {}{}\n", native_str, os.name);
    // }

    // stdout.write("Environments:\n");
    // for (builtin.Environ) |environ| {
    //     const native_str = ""; // if (builtin.environ == environ) " (native) " else "";
    //     stdout.print("   {}{}\n", native_str, environ.name);
    // }
    try alwaysOk();
}

// version /////////////////////////////////////////////////////////////////////////////////////////

fn cmdVersion(allocator: &Allocator, args: []const []const u8) !void {
    const c = struct { const ZIG_VERSION_STRING = c"placeholder"; };

    try stdout.print("{}\n", std.cstr.toSliceConst(c.ZIG_VERSION_STRING));
}

// help ////////////////////////////////////////////////////////////////////////////////////////////

fn cmdHelp(allocator: &Allocator, args: []const []const u8) !void {
    try stderr.write(usage);
}

// zen /////////////////////////////////////////////////////////////////////////////////////////////

const info_zen =
    \\
    \\ * Communicate intent precisely.
    \\ * Edge cases matter.
    \\ * Favor reading code over writing code.
    \\ * Only one obvious way to do things.
    \\ * Runtime crashes are better than bugs.
    \\ * Compile errors are better than runtime crashes.
    \\ * Incremental improvements.
    \\ * Avoid local maximums.
    \\ * Reduce the amount one must remember.
    \\ * Minimize energy spent on coding style.
    \\ * Together we serve end users.
    \\
    \\
    ;

fn cmdZen(allocator: &Allocator, args: []const []const u8) !void {
    try stdout.write(info_zen);
}

// BUILD_INFO //////////////////////////////////////////////////////////////////////////////////////

fn cmdBuildInfo(allocator: &Allocator, args: []const []const u8) !void {
    const c = struct {
        const ZIG_CMAKE_BINARY_DIR = "placeholder";
        const ZIG_CXX_COMPILER = "placeholder";
        const ZIG_LLVM_CONFIG_EXE = "placeholder";
        const ZIG_LLD_INCLUDE_PATH = "placeholder";
        const ZIG_LLD_LIBRARIES = "placeholder";
        const ZIG_STD_FILES = "placeholder";
        const ZIG_C_HEADER_FILES = "placeholder";
        const ZIG_DIA_GUIDS_LIB = "placeholder";
    };

    try stdout.print(
        \\ZIG_CMAKE_BINARY_DIR {}
        \\ZIG_CXX_COMPILER     {}
        \\ZIG_LLVM_CONFIG_EXE  {}
        \\ZIG_LLD_INCLUDE_PATH {}
        \\ZIG_LLD_LIBRARIES    {}
        \\ZIG_STD_FILES        {}
        \\ZIG_C_HEADER_FILES   {}
        \\ZIG_DIA_GUIDS_LIB    {}
        \\
        ,
        c.ZIG_CMAKE_BINARY_DIR,
        c.ZIG_CXX_COMPILER,
        c.ZIG_LLVM_CONFIG_EXE,
        c.ZIG_LLD_INCLUDE_PATH,
        c.ZIG_LLD_LIBRARIES,
        c.ZIG_STD_FILES,
        c.ZIG_C_HEADER_FILES,
        c.ZIG_DIA_GUIDS_LIB,
    );
}
