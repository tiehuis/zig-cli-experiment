const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;

// 32-bit FNV-1a
fn hash_str(str: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (str) |b| {
        hash = hash ^ b;
        hash = hash *% 16777619;
    }
    return hash;
}

fn eql_str(a: []const u8, b: []const u8) bool {
    return mem.eql(u8, a, b);
}

const HashMapFlags = HashMap([]const u8, FlagArgs, hash_str, eql_str);

// A store for querying found flags and positional arguments.
pub const Args = struct {
    flags: HashMapFlags,
    positionals: ArrayList([]const u8),

    pub fn parse(allocator: &Allocator, comptime spec: []const Flag, args: []const []const u8) !Args {
        var parsed = Args {
            .flags = HashMapFlags.init(allocator),
            .positionals = ArrayList([]const u8).init(allocator),
        };


        next: for (args) |arg| {
            if (mem.eql(u8, "--", arg[0..2])) {
                // TODO: struct/hashmap lookup would be nice here.
                for (spec) |flag| {
                    if (mem.eql(u8, arg[2..], flag.name)) {
                        _ = try parsed.flags.put(flag.name, FlagArgs.None);

                        // parse positionals

                        continue :next;
                    }
                }

                // TODO: Better errors with context
                return error.UnknownArgument;
            } else {
                try parsed.positionals.append(arg);
            }
        }

        return parsed;
    }

    pub fn deinit(self: &Args) void {
        self.flags.deinit();
        self.positionals.deinit();
    }

    // e.g. --help
    pub fn present(self: &Args, name: []const u8) bool {
        return self.flags.contains(name);
    }

    // e.g. --name value
    pub fn single(self: &Args, name: []const u8) []const u8 {
        // TODO: Can we enforce these accesses at compile-time, need to move to a struct instead
        // of a hash-map in that case. Assume the user has handled the required options according
        // to the given spec.
        if (self.flags.get(name)) |entry| {
            switch (entry.value) {
                FlagArgs.Single => |inner| { return inner; },
                else => @panic("attempted to retrieve flag with wrong type: {}", name),
            }
        } else {
            @panic("attempted to retrieve unspecified flag: {}", name);
        }
    }

    // e.g. --names value1 value2 value3
    pub fn many(self: &Args, name: []const u8) []const []const u8 {
        if (self.flags.get(name)) |entry| {
            switch (entry.value) {
                FlagArgs.Many => |inner| { return inner.toSliceConst(); },
                else => @panic("attempted to retrieve flag with wrong type: {}", name),
            }
        } else {
            @panic("attempted to retrieve unspecified flag: {}", name);
        }
    }
};

// Arguments for a flag. e.g. --command arg1 arg2.
const FlagArgs = union(enum) {
    None,
    Single: []const []const u8,
    Many: ArrayList([]const []const u8),
};

// Specification for how a flag should be parsed.
pub const Flag = struct {
    name: []const u8,
    required: ?usize,

    pub fn Bool(comptime name: []const u8) Flag {
        return ArgN(name, 0);
    }

    pub fn Arg1(comptime name: []const u8) Flag {
        return ArgN(name, 1);
    }

    pub fn ArgN(comptime name: []const u8, comptime n: ?usize) Flag {
        return Flag {
            .name = name,
            .required = n,
        };
    }
};

test "example" {
    const spec1 = comptime []const Flag {
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

    const cliargs = []const []const u8 {
        "zig",
        "build",
        "--help",
        "value",
        "--init",
        "pos1",
        "pos2",
        "pos3",
        "pos4",
    };

    var args = try Args.parse(std.debug.global_allocator, spec1, cliargs);

    std.debug.warn("help: {}\n", args.present("help"));
    std.debug.warn("init: {}\n", args.present("init"));
    std.debug.warn("init2: {}\n", args.present("init2"));
}
