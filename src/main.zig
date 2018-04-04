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
const introspect = @import("introspect.zig");
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

const usage =
    \\usage: zig [command] [options]
    \\
    \\Commands:
    \\
    \\  build                        Build project from build.zig
    \\  build-exe   [source]         Create executable from source or object files
    \\  build-lib   [source]         Create library from source or object files
    \\  build-obj   [source]         Create object from source or assembly
    \\  cc          [args]           Call the system c compiler and pass args through
    \\  fmt         [source]         Parse file and render in canonical zig format
    \\  run         [source]         Create executable and run immediately
    \\  targets                      List available compilation targets
    \\  test        [source]         Create and run a test build
    \\  translate-c [source]         Convert c code to zig code
    \\  version                      Print version number and exit
    \\  zen                          Print zen of zig and exit
    \\
    \\
    ;

const Command = struct {
    name: []const u8,
    exec: fn(&Allocator, []const []const u8) error!void,
};

pub fn main() !void {
    // TODO: Need a generic allocator since we use unbounded memory for things like fmt and building
    // if we do in process.
    var mem_buf: [1024 * 512]u8 = undefined;
    var fixed_allocator = std.heap.FixedBufferAllocator.init(mem_buf[0..]);
    const allocator = &fixed_allocator.allocator;

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
        Command { .name = "run",         .exec = cmdRun        },
        Command { .name = "targets",     .exec = cmdTargets    },
        Command { .name = "test",        .exec = cmdTest       },
        Command { .name = "translate-c", .exec = cmdTranslateC },
        Command { .name = "version",     .exec = cmdVersion    },
        Command { .name = "zen",         .exec = cmdZen        },

        // undocumented commands
        Command { .name = "help",        .exec = cmdHelp       },
        Command { .name = "internal",    .exec = cmdInternal   },
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
    \\   --help                       Print this help and exit
    \\   --init                       Generate a build.zig template
    \\   --build-file [file]          Override path to build.zig
    \\   --cache-dir [path]           Override path to cache directory
    \\   --verbose                    Print commands before executing them
    \\   --prefix [path]              Override default install prefix
    \\   --zig-install-prefix [path]  Override directory where zig thinks it is installed
    \\
    \\Advanced Options:
    \\   --build-file [file]          Override path to build.zig
    \\   --cache-dir [path]           Override path to cache directory
    \\   --verbose-tokenize           Enable compiler debug output for tokenization
    \\   --verbose-ast                Enable compiler debug output for parsing into an AST
    \\   --verbose-link               Enable compiler debug output for linking
    \\   --verbose-ir                 Enable compiler debug output for Zig IR
    \\   --verbose-llvm-ir            Enable compiler debug output for LLVM IR
    \\   --verbose-cimport            Enable compiler debug output for C imports
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
    Flag.Arg1("--zig-install-prefix"),

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
    \\
    \\Initialize a 'build.zig' template file with `zig build --init`,
    \\or build an executable directly with `zig build-exe $FILENAME.zig`.
    \\
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

    const zig_lib_dir = try introspect.resolveZigLibDir(allocator, flags.single("zig-install-prefix") ?? null);
    defer allocator.free(zig_lib_dir);

    const zig_std_dir = try os.path.join(allocator, zig_lib_dir, "std");
    defer allocator.free(zig_std_dir);

    const special_dir = try os.path.join(allocator, zig_std_dir, "special");
    defer allocator.free(special_dir);

    const build_runner_path = try os.path.join(allocator, special_dir, "build_runner.zig");
    defer allocator.free(build_runner_path);

    const build_file = flags.single("build-file") ?? "build.zig";
    const build_file_abs = try os.path.resolve(allocator, ".", build_file);
    defer allocator.free(build_file_abs);

    const build_file_exists = fileExists(allocator, build_file_abs);

    if (flags.present("init")) {
        if (build_file_exists) {
            try stderr.print("build.zig already exists\n");
            return;
        }

        const build_template_path = try os.path.join(allocator, special_dir, "build_file_template.zig");
        defer allocator.free(build_template_path);

        try os.copyFile(allocator, build_template_path, build_file_abs);

        try stderr.print("wrote build.zig template\n");
        return;
    }

    if (!build_file_exists) {
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
    \\  --help                       Print this help and exit
    \\  --color [auto|off|on]        Enable or disable colored error messages
    \\
    \\Compile Options:
    \\  --assembly [source]          Add assembly file to build
    \\  --cache-dir [path]           Override the cache directory
    \\  --emit [filetype]            Emit a specific file format as compilation output
    \\  --enable-timing-info         Print timing diagnostics
    \\  --libc-include-dir [path]    Directory where libc stdlib.h resides
    \\  --name [name]                Override output name
    \\  --output [file]              Override destination path
    \\  --output-h [file]            Override generated header file path
    \\  --pkg-begin [name] [path]    Make package available to import and push current pkg
    \\  --pkg-end                    Pop current pkg
    \\  --release-fast               Build with optimizations on and safety off
    \\  --release-safe               Build with optimizations on and safety on
    \\  --static                     Output will be statically linked
    \\  --strip                      Exclude debug symbols
    \\  --target-arch [name]         Specify target architecture
    \\  --target-environ [name]      Specify target environment
    \\  --target-os [name]           Specify target operating system
    \\  --verbose-tokenize           Turn on compiler debug output for tokenization
    \\  --verbose-ast                Turn on compiler debug output for parsing into an AST
    \\  --verbose-link               Turn on compiler debug output for linking
    \\  --verbose-ir                 Turn on compiler debug output for Zig IR
    \\  --verbose-llvm-ir            Turn on compiler debug output for LLVM IR
    \\  --verbose-cimport            Turn on compiler debug output for C imports
    \\  --zig-install-prefix [path]  Override directory where zig thinks it is installed
    \\  -dirafter [dir]              Same as -isystem but do it last
    \\  -isystem [dir]               Add additional search path for other .h files
    \\  -mllvm [arg]                 Additional arguments to forward to LLVM's option processing
    \\
    \\Link Options:
    \\  --ar-path [path]             Set the path to ar
    \\  --dynamic-linker [path]      Set the path to ld.so
    \\  --each-lib-rpath             Add rpath for each used dynamic library
    \\  --libc-lib-dir [path]        Directory where libc crt1.o resides
    \\  --libc-static-lib-dir [path] Directory where libc crtbegin.o resides
    \\  --msvc-lib-dir [path]        (windows) directory where vcruntime.lib resides
    \\  --kernel32-lib-dir [path]    (windows) directory where kernel32.lib resides
    \\  --library [lib]              Link against lib
    \\  --forbid-library [lib]       Make it an error to link against lib
    \\  --library-path [dir]         Add a directory to the library search path
    \\  --linker-script [path]       Use a custom linker script
    \\  --object [obj]               Add object file to build
    \\  -rdynamic                    Add all symbols to the dynamic symbol table
    \\  -rpath [path]                Add directory to the runtime library search path
    \\  -mconsole                    (windows) --subsystem console to the linker
    \\  -mwindows                    (windows) --subsystem windows to the linker
    \\  -framework [name]            (darwin) link against framework
    \\  -mios-version-min [ver]      (darwin) set iOS deployment target
    \\  -mmacosx-version-min [ver]   (darwin) set Mac OS X deployment target
    \\  --ver-major [ver]            Dynamic library semver major version
    \\  --ver-minor [ver]            Dynamic library semver minor version
    \\  --ver-patch [ver]            Dynamic library semver patch version
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
    // TODO: pkg-begin needs to be ended by a corresponding pkg-end, add ability for this
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

const OutputType = enum {
    Exe,
    Obj,
    Lib,
};

fn cmdBuildExe(allocator: &Allocator, args: []const []const u8) !void {
    var flags = try Args.parse(allocator, args_build_generic, args);
    defer flags.deinit();

    if (flags.present("help")) {
        try stderr.write(usage_build_generic);
        return;
    }

    // We can consolidate all the build-exe, build-lib, build-obj into a single path once we
    // set the output type. Check if we should do any specific passing prior.
    //
    // test is similar, although the end differs. so possibly consolidate codegen setup and take
    // a different path on the end.
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
    // TODO: Would be nice to use libclang directly but I don't think the argument parsing is
    // exposed in an easy to use way.
    var command = ArrayList([]const u8).init(allocator);
    defer command.deinit();

    try command.append("cc");
    try command.appendSlice(args);

    var proc = try os.ChildProcess.init(command.toSliceConst(), allocator);
    defer proc.deinit();

    var term = try proc.spawnAndWait();
    switch (term) {
        os.ChildProcess.Term.Exited => |status| {
            if (status != 0) {
                warn("cc exited with status {}\n", status);
                os.exit(1);
            }
        },
        os.ChildProcess.Term.Signal => |signal| {
            warn("cc killed by signal {}\n", signal);
            os.exit(1);
        },
        os.ChildProcess.Term.Stopped => |signal| {
            warn("cc stopped by signal {}\n", signal);
            os.exit(1);
        },
        os.ChildProcess.Term.Unknown => |status| {
            warn("cc encountered unknown failure {}\n", status);
            os.exit(1);
        },
    }
}

// fmt /////////////////////////////////////////////////////////////////////////////////////////////

const usage_fmt =
    \\usage: zig fmt [file]...
    \\
    \\   Formats the input files and modifies them in-place.
    \\
    \\Options:
    \\   --help                 Print this help and exit
    \\   --keep-backups         Retain backup entries for every file
    \\
    \\
    ;

const args_fmt_spec = []Flag {
    Flag.Bool("--help"),
    Flag.Bool("--keep-backups"),
};

fn cmdFmt(allocator: &Allocator, args: []const []const u8) !void {
    var flags = try Args.parse(allocator, args_fmt_spec, args);
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
        var file = try os.File.openRead(allocator, file_path);
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

        var original_file_backup = try Buffer.init(allocator, file_path);
        defer original_file_backup.deinit();
        try original_file_backup.append(".backup");

        try os.rename(allocator, file_path, original_file_backup.toSliceConst());

        std.debug.warn("{}\n", file_path);

        // TODO: BufferedAtomicFile has some access problems.
        var out_file = try os.File.openWrite(allocator, file_path);
        defer out_file.close();

        var out_file_stream = io.FileOutStream.init(&out_file);
        try parser.renderSource(out_file_stream.stream, tree.root_node);

        if (!flags.present("keep-backups")) {
            try os.deleteFile(allocator, original_file_backup.toSliceConst());
        }
    }
}

// targets /////////////////////////////////////////////////////////////////////////////////////////

// TODO: comptime '@fields' for iteration here instead so we are always in sync.
const Os = builtin.Os;
pub const os_list = []const Os {
    Os.freestanding,
    Os.ananas,
    Os.cloudabi,
    Os.dragonfly,
    Os.freebsd,
    Os.fuchsia,
    Os.ios,
    Os.kfreebsd,
    Os.linux,
    Os.lv2,
    Os.macosx,
    Os.netbsd,
    Os.openbsd,
    Os.solaris,
    Os.windows,
    Os.haiku,
    Os.minix,
    Os.rtems,
    Os.nacl,
    Os.cnk,
    // Os.bitrig,
    Os.aix,
    Os.cuda,
    Os.nvcl,
    Os.amdhsa,
    Os.ps4,
    Os.elfiamcu,
    Os.tvos,
    Os.watchos,
    Os.mesa3d,
    Os.contiki,
    Os.zen,
};

const Arch = builtin.Arch;
pub const arch_list = []const Arch {
    Arch.armv8_2a,
    Arch.armv8_1a,
    Arch.armv8,
    Arch.armv8r,
    Arch.armv8m_baseline,
    Arch.armv8m_mainline,
    Arch.armv7,
    Arch.armv7em,
    Arch.armv7m,
    Arch.armv7s,
    Arch.armv7k,
    Arch.armv7ve,
    Arch.armv6,
    Arch.armv6m,
    Arch.armv6k,
    Arch.armv6t2,
    Arch.armv5,
    Arch.armv5te,
    Arch.armv4t,
    // Arch.armeb,
    Arch.aarch64,
    Arch.aarch64_be,
    Arch.avr,
    Arch.bpfel,
    Arch.bpfeb,
    Arch.hexagon,
    Arch.mips,
    Arch.mipsel,
    Arch.mips64,
    Arch.mips64el,
    Arch.msp430,
    Arch.nios2,
    Arch.powerpc,
    Arch.powerpc64,
    Arch.powerpc64le,
    Arch.r600,
    Arch.amdgcn,
    Arch.riscv32,
    Arch.riscv64,
    Arch.sparc,
    Arch.sparcv9,
    Arch.sparcel,
    Arch.s390x,
    Arch.tce,
    Arch.tcele,
    Arch.thumb,
    Arch.thumbeb,
    Arch.i386,
    Arch.x86_64,
    Arch.xcore,
    Arch.nvptx,
    Arch.nvptx64,
    Arch.le32,
    Arch.le64,
    Arch.amdil,
    Arch.amdil64,
    Arch.hsail,
    Arch.hsail64,
    Arch.spir,
    Arch.spir64,
    Arch.kalimbav3,
    Arch.kalimbav4,
    Arch.kalimbav5,
    Arch.shave,
    Arch.lanai,
    Arch.wasm32,
    Arch.wasm64,
    Arch.renderscript32,
    Arch.renderscript64,
};

const Environ = builtin.Environ;
pub const environ_list = []const Environ {
    Environ.unknown,
    Environ.gnu,
    Environ.gnuabi64,
    Environ.gnueabi,
    Environ.gnueabihf,
    Environ.gnux32,
    Environ.code16,
    Environ.eabi,
    Environ.eabihf,
    Environ.android,
    Environ.musl,
    Environ.musleabi,
    Environ.musleabihf,
    Environ.msvc,
    Environ.itanium,
    Environ.cygnus,
    Environ.amdopencl,
    Environ.coreclr,
    Environ.opencl,
};

fn cmdTargets(allocator: &Allocator, args: []const []const u8) !void {
    try stdout.write("Architectures:\n");
    for (arch_list) |arch_tag| {
        const native_str = if (builtin.arch == arch_tag) " (native) " else "";
        try stdout.print("  {}{}\n", @tagName(arch_tag), native_str);
    }
    try stdout.write("\n");

    try stdout.write("Operating Systems:\n");
    for (os_list) |os_tag| {
        const native_str = if (builtin.os == os_tag) " (native) " else "";
        try stdout.print("  {}{}\n", @tagName(os_tag), native_str);
    }
    try stdout.write("\n");

    try stdout.write("Environments:\n");
    for (environ_list) |environ_tag| {
        const native_str = if (builtin.environ == environ_tag) " (native) " else "";
        try stdout.print("  {}{}\n", @tagName(environ_tag), native_str);
    }
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

    if (flags.positionals.len != 1) {
        try stderr.write("expected exactly one zig source file\n");
        return;
    }

    // compile the test program into the cache and run
}

// run ////////////////////////////////////////////////////////////////////////////////////////////

// TODO: We may want to simplify the run interface. It should be for simple quick scripts and if you
// need something more complex use `zig build-exe` and run manually.
const usage_run =
    \\usage: zig run [file] -- <runtime args>
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
    var compile_args = args;
    var runtime_args: []const []const u8 = []const []const u8 {};

    for (args) |argv, i| {
        if (mem.eql(u8, argv, "--")) {
            compile_args = args[0..i];
            runtime_args = args[i+1..];
            break;
        }
    }

    var flags = try Args.parse(allocator, args_run_spec, compile_args);
    defer flags.deinit();

    if (flags.present("help")) {
        try stderr.write(usage_run);
        return;
    }

    if (flags.positionals.len != 1) {
        try stderr.write("expected exactly one zig source file\n");
        return;
    }

    warn("runtime args:\n");
    for (runtime_args) |cargs| {
        warn("{}\n", cargs);
    }
}

// translate-c /////////////////////////////////////////////////////////////////////////////////////

const usage_translate_c =
    \\usage: zig translate-c [file]
    \\
    \\Options:
    \\  --help                       Print this help and exit
    \\  --enable-timing-info         Print timing diagnostics
    \\  --libc-include-dir [path]    Directory where libc stdlib.h resides
    \\  --output [path]              Output file to write generated zig file (default: stdout)
    \\
    \\
    ;

const args_translate_c_spec = []Flag {
    Flag.Bool("--help"),
    Flag.Bool("--enable-timing-info"),
    Flag.Arg1("--libc-include-dir"),
    Flag.Arg1("--output"),
};

fn cmdTranslateC(allocator: &Allocator, args: []const []const u8) !void {
    var flags = try Args.parse(allocator, args_translate_c_spec, args);
    defer flags.deinit();

    if (flags.present("help")) {
        try stderr.write(usage_translate_c);
        return;
    }

    if (flags.positionals.len != 1) {
        try stderr.write("expected exactly one c source file\n");
        return;
    }

    // set up codegen

    const zig_root_source_file = null;

    // can we limit this to just what we need, i'm pretty sure the C++ version
    // sets way more than we need and there are very few applicable arguments.

    // codegen_create(g);
    // codegen_set_out_name(g, null);
    // codegen_set_libc_include_dir(g);
    // codegen_translate_c(g, flags.positional.at(0))

    var output_stream = stdout;
    if (flags.single("output")) |output_file| {
        var file = try os.File.openWrite(allocator, output_file);
        defer file.close();

        var file_stream = io.FileOutStream.init(&file);
        // TODO: Not being set correctly, still stdout
        output_stream = &file_stream.stream;
    }

    // ast_render(g, output_stream, g->root_import->root, 4);
    try output_stream.write("pub const example = 10;\n");

    if (flags.present("enable-timing-info")) {
        // codegen_print_timing_info(g, stdout);
        try stderr.write("printing timing info for translate-c\n");
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

// internal ////////////////////////////////////////////////////////////////////////////////////////

const usage_internal =
    \\usage: zig internal [subcommand]
    \\
    \\Sub-Commands:
    \\  build-info                   Print static compiler build-info
    \\
    \\
    ;

fn cmdInternal(allocator: &Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr.write(usage_internal);
        return;
    }

    const sub_commands = []Command {
        Command { .name = "build-info", .exec = cmdInternalBuildInfo },
    };

    inline for (sub_commands) |sub_command| {
        if (mem.eql(u8, sub_command.name, args[0])) {
            try sub_command.exec(allocator, args[1..]);
            return;
        }
    }

    try stderr.print("unknown sub command: {}\n\n", args[0]);
    try stderr.write(usage_internal);
}

fn cmdInternalBuildInfo(allocator: &Allocator, args: []const []const u8) !void {
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
        \\# ZIG_CMAKE_BINARY_DIR {}
        \\# ZIG_CXX_COMPILER     {}
        \\# ZIG_LLVM_CONFIG_EXE  {}
        \\# ZIG_LLD_INCLUDE_PATH {}
        \\# ZIG_LLD_LIBRARIES    {}
        \\# ZIG_STD_FILES        {}
        \\# ZIG_C_HEADER_FILES   {}
        \\# ZIG_DIA_GUIDS_LIB    {}
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
