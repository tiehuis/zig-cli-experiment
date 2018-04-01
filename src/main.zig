const std = @import("std");
const builtin = @import("builtin");

const os = std.os;
const io = std.io;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Buffer = std.Buffer;

const warn = std.debug.warn;

const arg = @import("arg.zig");
const Args = arg.Args;
const Flag = arg.Flag;

var stderr: &io.OutStream(io.FileOutStream.Error) = undefined;
var stdout: &io.OutStream(io.FileOutStream.Error) = undefined;

// TODO: might want these in std
fn fileExists(allocator: &Allocator, path: []const u8) bool {
    if (os.File.openRead(allocator, path)) |*file| {
        file.close();
        return true;
    } else |_| {
        return false;
    }
}

/// Caller must free result
fn testZigInstallPrefix(allocator: &mem.Allocator, test_path: []const u8) ![]u8 {
    const test_zig_dir = try os.path.join(allocator, test_path, "lib", "zig");
    errdefer allocator.free(test_zig_dir);

    const test_index_file = try os.path.join(allocator, test_zig_dir, "std", "index.zig");
    defer allocator.free(test_index_file);

    var file = try os.File.openRead(allocator, test_index_file);
    file.close();

    return test_zig_dir;
}

/// Caller must free result
fn findZigLibDir(allocator: &mem.Allocator) ![]u8 {
    const self_exe_path = try os.selfExeDirPath(allocator);
    defer allocator.free(self_exe_path);

    var cur_path: []const u8 = self_exe_path;
    while (true) {
        const test_dir = os.path.dirname(cur_path);

        if (mem.eql(u8, test_dir, cur_path)) {
            break;
        }

        return testZigInstallPrefix(allocator, test_dir) catch |err| {
            cur_path = test_dir;
            continue;
        };
    }

    // TODO look in hard coded installation path from configuration
    //if (ZIG_INSTALL_PREFIX != nullptr) {
    //    if (test_zig_install_prefix(buf_create_from_str(ZIG_INSTALL_PREFIX), out_path)) {
    //        return 0;
    //    }
    //}

    return error.FileNotFound;
}

fn resolveZigLibDir(allocator: &mem.Allocator, zig_install_prefix_arg: ?[]const u8) ![]u8 {
    if (zig_install_prefix_arg) |zig_install_prefix| {
        return testZigInstallPrefix(allocator, zig_install_prefix) catch |err| {
            warn("No Zig installation found at prefix {}: {}\n", zig_install_prefix_arg, @errorName(err));
            return error.ZigInstallationNotFound;
        };
    } else {
        return findZigLibDir(allocator) catch |err| {
            warn(
                \\Unable to find zig lib directory: {}.
                \\Reinstall Zig or use --zig-install-prefix.
                \\
                ,
                @errorName(err)
            );

            return error.ZigLibDirNotFound;
        };
    }
}

const usage =
    \\usage: zig [command] [options]
    \\
    \\Commands:
    \\
    \\  build                        build project from build.zig
    \\  build-exe   [source]         create executable from source or object files
    \\  build-lib   [source]         create library from source or object files
    \\  build-obj   [source]         create object from source or assembly
    \\  cc          [args]           call the system c compiler and pass args through
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
        Command { .name = "build",       .exec = cmdBuild      },
        Command { .name = "build-exe",   .exec = cmdBuildExe   },
        Command { .name = "build-lib",   .exec = cmdBuildLib   },
        Command { .name = "build-obj",   .exec = cmdBuildObj   },
        Command { .name = "cc",          .exec = cmdCc         },
        Command { .name = "fmt",         .exec = cmdFmt        },
        Command { .name = "help",        .exec = cmdHelp       },
        Command { .name = "run",         .exec = cmdRun        },
        Command { .name = "translate-c", .exec = cmdTranslateC },
        Command { .name = "targets",     .exec = cmdTargets    },
        Command { .name = "test",        .exec = cmdTest       },
        Command { .name = "version",     .exec = cmdVersion    },
        Command { .name = "zen",         .exec = cmdZen        },

        // non user facing commands
        Command { .name = "BUILD_INFO",  .exec = cmdBuildInfo  },
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
    Flag.Bool("--help"),
    Flag.Bool("--init"),
    Flag.Arg1("--build-file"),
    Flag.Arg1("--cache-dir"),
    Flag.Bool("--verbose"),
    Flag.Arg1("--prefix"),
    Flag.Arg1("--build-file"),
    Flag.Arg1("--cache-dir"),
    Flag.Bool("--verbose-tokenize"),
    Flag.Bool("--verbose-ast"),
    Flag.Bool("--verbose-link"),
    Flag.Bool("--verbose-ir"),
    Flag.Bool("--verbose-llvm-ir"),
    Flag.Bool("--verbose-cimport"),
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

    // TODO: Maybe get all these special paths and return as a struct.
    const zig_lib_dir = try resolveZigLibDir(allocator, flags.single("zig_install_prefix") ?? null);
    defer allocator.free(zig_lib_dir);

    const zig_std_dir = try os.path.join(allocator, zig_lib_dir, "std");
    defer allocator.free(zig_std_dir);

    const special_dir = try os.path.join(allocator, zig_std_dir, "special");
    defer allocator.free(special_dir);

    const build_runner_path = try os.path.join(allocator, special_dir, "build_runner.zig");
    defer allocator.free(build_runner_path);

    const build_file = flags.single("build-file") ?? "build-zig";
    const build_file_abs = try os.path.resolve(allocator, ".", build_file);
    defer allocator.free(build_file_abs);

    const build_file_exists = fileExists(allocator, build_file_abs);

    if (flags.present("init")) {
        if (build_file_exists) {
            return;
        }

        const build_template_path = try os.path.join(allocator, special_dir, "build_file_template.zig");
        defer allocator.free(build_template_path);

        var src_file = try os.File.openRead(allocator, build_template_path);
        defer src_file.close();

        var dst_file = try os.File.openWrite(allocator, build_file_abs);
        defer dst_file.close();

        // TODO: CopyFile?
        while (true) {
            var buffer: [4096]u8 = undefined;
            const n = try src_file.read(buffer[0..]);
            if (n == 0) break;
            try dst_file.write(buffer[0..n]);
        }

        try stderr.print("wrote build.zig template\n");
        return;
    }

    if (build_file_exists) {
        try stderr.write(missing_build_file);
        return;
    }

    // TODO: Invoke the build_runner directly and circumvent running the compiler in a subprocess.
    var zig_exe_path = try os.selfExePath(allocator);
    defer allocator.free(zig_exe_path);

    var build_args = ArrayList([]const u8).init(allocator);
    defer build_args.deinit();

    const build_file_basename = os.path.basename(build_file_abs);
    const build_file_dirname = os.path.dirname(build_file_abs);

    var full_cache_dir: []u8 = undefined;
    if (flags.single("cache-dir")) |cache_dir| {
        full_cache_dir = try os.path.resolve(allocator, ".", cache_dir, full_cache_dir);
    } else {
        full_cache_dir = try os.path.join(allocator, build_file_dirname, "zig-cache");
    }
    defer allocator.free(full_cache_dir);

    const path_to_build_exe = try os.path.join(allocator, full_cache_dir, "build");
    defer allocator.free(path_to_build_exe);

    try build_args.append(path_to_build_exe);
    try build_args.append(zig_exe_path);
    try build_args.append(build_file_dirname);
    try build_args.append(full_cache_dir);

    if (flags.single("zig-install-prefix")) |zig_install_prefix| {
        try build_args.append(zig_install_prefix);
    }

    var proc = try os.ChildProcess.init(build_args.toSliceConst(), allocator);
    defer proc.deinit();

    var term = try proc.spawnAndWait();
    switch (term) {
        os.ChildProcess.Term.Exited => |status| {
            if (status != 0) {
                warn("{} exited with status {}\n", build_args.at(0), status);
                os.exit(1);
            }
        },
        os.ChildProcess.Term.Signal => |signal| {
            warn("{} killed by signal {}\n", build_args.at(0), signal);
            os.exit(1);
        },
        os.ChildProcess.Term.Stopped => |signal| {
            warn("{} stopped by signal {}\n", build_args.at(0), signal);
            os.exit(1);
        },
        os.ChildProcess.Term.Unknown => |status| {
            warn("{} encountered unknown failure {}\n", build_args.at(0), status);
            os.exit(1);
        },
    }
}

// build-exe ///////////////////////////////////////////////////////////////////////////////////////

const usage_build_generic =
    \\usage: zig build-exe <options> [file]
    \\       zig build-lib <options> [file]
    \\       zig build-obj <options> [file]
    \\
    \\General Options
    \\  --help                       print this help and exit
    \\  --color [auto|off|on]        enable or disable colored error messages
    \\
    \\Compile Options:
    \\  --assembly [source]          add assembly file to build
    \\  --cache-dir [path]           override the cache directory
    \\  --emit [filetype]            emit a specific file format as compilation output
    \\  --enable-timing-info         print timing diagnostics
    \\  --libc-include-dir [path]    directory where libc stdlib.h resides
    \\  --name [name]                override output name
    \\  --output [file]              override destination path
    \\  --output-h [file]            override generated header file path
    \\  --pkg-begin [name] [path]    make package available to import and push current pkg
    \\  --pkg-end                    pop current pkg
    \\  --release-fast               build with optimizations on and safety off
    \\  --release-safe               build with optimizations on and safety on
    \\  --static                     output will be statically linked
    \\  --strip                      exclude debug symbols
    \\  --target-arch [name]         specify target architecture
    \\  --target-environ [name]      specify target environment
    \\  --target-os [name]           specify target operating system
    \\  --verbose-tokenize           turn on compiler debug output for tokenization
    \\  --verbose-ast                turn on compiler debug output for parsing into an AST
    \\  --verbose-link               turn on compiler debug output for linking
    \\  --verbose-ir                 turn on compiler debug output for Zig IR
    \\  --verbose-llvm-ir            turn on compiler debug output for LLVM IR
    \\  --verbose-cimport            turn on compiler debug output for C imports
    \\  --zig-install-prefix [path]  override directory where zig thinks it is installed
    \\  -dirafter [dir]              same as -isystem but do it last
    \\  -isystem [dir]               add additional search path for other .h files
    \\  -mllvm [arg]                 additional arguments to forward to LLVM's option processing
    \\
    \\Link Options:
    \\  --ar-path [path]             set the path to ar
    \\  --dynamic-linker [path]      set the path to ld.so
    \\  --each-lib-rpath             add rpath for each used dynamic library
    \\  --libc-lib-dir [path]        directory where libc crt1.o resides
    \\  --libc-static-lib-dir [path] directory where libc crtbegin.o resides
    \\  --msvc-lib-dir [path]        (windows) directory where vcruntime.lib resides
    \\  --kernel32-lib-dir [path]    (windows) directory where kernel32.lib resides
    \\  --library [lib]              link against lib
    \\  --forbid-library [lib]       make it an error to link against lib
    \\  --library-path [dir]         add a directory to the library search path
    \\  --linker-script [path]       use a custom linker script
    \\  --object [obj]               add object file to build
    \\  -rdynamic                    add all symbols to the dynamic symbol table
    \\  -rpath [path]                add directory to the runtime library search path
    \\  -mconsole                    (windows) --subsystem console to the linker
    \\  -mwindows                    (windows) --subsystem windows to the linker
    \\  -framework [name]            (darwin) link against framework
    \\  -mios-version-min [ver]      (darwin) set iOS deployment target
    \\  -mmacosx-version-min [ver]   (darwin) set Mac OS X deployment target
    \\  --ver-major [ver]            dynamic library semver major version
    \\  --ver-minor [ver]            dynamic library semver minor version
    \\  --ver-patch [ver]            dynamic library semver patch version
    \\
    \\
    ;

const args_build_generic = []Flag {
    Flag.Bool("--help"),
    Flag.Option("--color", []const []const u8 { "auto", "off", "on" }),

    Flag.Arg1("--assembly"),
    Flag.Arg1("--cache-dir"),
    Flag.Option("--emit", []const []const u8 { "asm", "bin", "llvm-ir" }),
    Flag.Bool("--enable-timing-info"),
    Flag.Arg1("--libc-include-dir"),
    Flag.Arg1("--name"),
    Flag.Arg1("--output"),
    Flag.Arg1("--output-h"),
    Flag.ArgN("--pkg-begin", 2),
    Flag.Bool("--pkg-end"),
    Flag.Bool("--release-fast"),
    Flag.Bool("--release-safe"),
    Flag.Bool("--static"),
    Flag.Bool("--strip"),
    Flag.Arg1("--target-arch"),
    Flag.Arg1("--target-environ"),
    Flag.Arg1("--target-os"),
    Flag.Bool("--verbose-tokenize"),
    Flag.Bool("--verbose-ast"),
    Flag.Bool("--verbose-link"),
    Flag.Bool("--verbose-ir"),
    Flag.Bool("--verbose-llvm-ir"),
    Flag.Bool("--verbose-cimport"),
    Flag.Arg1("--zig-install-prefix"),
    Flag.Arg1("-dirafter"),
    Flag.Arg1("-isystem"),
    Flag.Arg1("-mllvm"),

    Flag.Arg1("--ar-path"),
    Flag.Arg1("--dynamic-linker"),
    Flag.Bool("--each-lib-rpath"),
    Flag.Arg1("--libc-lib-dir"),
    Flag.Arg1("--libc-static-lib-dir"),
    Flag.Arg1("--msvc-lib-dir"),
    Flag.Arg1("--kernel32-lib-dir"),
    Flag.Arg1("--library"),
    Flag.Arg1("--forbid-library"),
    Flag.Arg1("--library-path"),
    Flag.Arg1("--linker-script"),
    Flag.Arg1("--object"),
    // NOTE: Removed -L since it would need to be special-cased and we have an alias in library-path
    Flag.Bool("-rdynamic"),
    Flag.Arg1("-rpath"),
    Flag.Bool("-mconsole"),
    Flag.Bool("-mwindows"),
    Flag.Arg1("-framework"),
    Flag.Arg1("-mios-version-min"),
    Flag.Arg1("-mmacosx-version-min"),
    Flag.Arg1("--ver-major"),
    Flag.Arg1("--ver-minor"),
    Flag.Arg1("--ver-patch"),
};

fn cmdBuildExe(allocator: &Allocator, args: []const []const u8) !void {
    var flags = try Args.parse(allocator, args_build_generic, args);
    defer flags.deinit();

    if (flags.present("help")) {
        try stderr.write(usage_build_generic);
        return;
    }
}

// build-lib ///////////////////////////////////////////////////////////////////////////////////////

fn cmdBuildLib(allocator: &Allocator, args: []const []const u8) !void {
    var flags = try Args.parse(allocator, args_build_generic, args);
    defer flags.deinit();

    if (flags.present("help")) {
        try stderr.write(usage_build_generic);
        return;
    }
}

// build-obj ///////////////////////////////////////////////////////////////////////////////////////

fn cmdBuildObj(allocator: &Allocator, args: []const []const u8) !void {
    var flags = try Args.parse(allocator, args_build_generic, args);
    defer flags.deinit();

    if (flags.present("help")) {
        try stderr.write(usage_build_generic);
        return;
    }
}

// cc //////////////////////////////////////////////////////////////////////////////////////////////

fn cmdCc(allocator: &Allocator, args: []const []const u8) !void {
    // pass through all arguments without parsing on our end to libclang or system cc
    try alwaysOk();
}

// fmt /////////////////////////////////////////////////////////////////////////////////////////////

const usage_fmt =
    \\usage: zig fmt [file]...
    \\
    \\   Formats the input files and modifies them in-place.
    \\
    \\Options:
    \\   --help                 Print this help and exit
    \\
    \\
    ;

const args_fmt_spec = []Flag {
    Flag.Bool("--help"),
};

fn cmdFmt(allocator: &Allocator, args: []const []const u8) !void {
    var flags = try Args.parse(allocator, args_build_spec, args);
    defer flags.deinit();

    if (flags.present("help")) {
        try stderr.write(usage_fmt);
        return;
    }

    if (flags.positionals.len == 0) {
        try stderr.write("expected at least one source file argument\n");
        return;
    }

    for (flags.positionals.toSliceConst()) |file_path| {
        warn("writing {}\n", file_path);

        var file = try os.File.openRead(allocator, file_path);
        var file_closed = false;
        defer file.close();

        const source_code = io.readFileAlloc(allocator, file_path) catch |err| {
            try stderr.print("unable to open '{}': {}", file_path, err);
            continue;
        };
        defer allocator.free(source_code);

        var tokenizer = std.zig.Tokenizer.init(source_code);
        var parser = std.zig.Parser.init(&tokenizer, allocator, file_path);
        defer parser.deinit();

        var tree = try parser.parse();
        defer tree.deinit();

        // TODO: EACCES, create a copy and do an atomic copy instead?
        const baf = try io.BufferedAtomicFile.create(allocator, file_path);
        defer baf.destroy();

        try parser.renderSource(baf.stream(), tree.root_node);
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

// test ////////////////////////////////////////////////////////////////////////////////////////////

const usage_test =
    \\usage: zig test [file]...
    \\
    \\Options:
    \\   --help                 Print this help and exit
    \\
    \\
    ;

const args_test_spec = []Flag {
    Flag.Bool("--help"),
};


fn cmdTest(allocator: &Allocator, args: []const []const u8) !void {
    var flags = try Args.parse(allocator, args_build_spec, args);
    defer flags.deinit();

    if (flags.present("help")) {
        try stderr.write(usage_test);
        return;
    }
}

// run ////////////////////////////////////////////////////////////////////////////////////////////

const usage_run =
    \\usage: zig run [file]...
    \\
    \\Options:
    \\   --help                 Print this help and exit
    \\
    \\
    ;

const args_run_spec = []Flag {
    Flag.Bool("--help"),
};


fn cmdRun(allocator: &Allocator, args: []const []const u8) !void {
    var flags = try Args.parse(allocator, args_build_spec, args);
    defer flags.deinit();

    if (flags.present("help")) {
        try stderr.write(usage_run);
        return;
    }
}

// translate-c /////////////////////////////////////////////////////////////////////////////////////

const usage_translate_c =
    \\usage: zig translate-c [file]...
    \\
    \\Options:
    \\   --help                 Print this help and exit
    \\
    \\
    ;

const args_translate_c_spec = []Flag {
    Flag.Bool("--help"),
};


fn cmdTranslateC(allocator: &Allocator, args: []const []const u8) !void {
    var flags = try Args.parse(allocator, args_build_spec, args);
    defer flags.deinit();

    if (flags.present("help")) {
        try stderr.write(usage_translate_c);
        return;
    }
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
