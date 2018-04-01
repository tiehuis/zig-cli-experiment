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

const HashMapFlags = HashMap([]const u8, FlagArg, hash_str, eql_str);

fn trimStart(slice: []const u8, ch: u8) []const u8 {
    var i: usize = 0;
    for (slice) |b| {
        if (b != '-') break;
        i += 1;
    }

    // '---' case?
    return slice[i..];
}

fn argInAllowedSet(maybe_set: ?[]const []const u8, arg: []const u8) bool {
    if (maybe_set) |set| {
        for (set) |possible| {
            if (mem.eql(u8, arg, possible)) {
                return true;
            }
        }
        return false;
    } else {
        return true;
    }
}

// modifies the current argument index during iteration
fn readFlagArguments(allocator: &Allocator, args: []const []const u8, required: usize,
                     allowed_set: ?[]const []const u8, index: &usize) !FlagArg {
    switch (required) {
        0 => return FlagArg { .None = undefined },  // TODO: Required to force non-tag but value
        1 => {
            if (*index + 1 >= args.len) {
                return error.MissingFlagArguments;
            }

            *index += 1;
            const arg = args[*index];

            if (!argInAllowedSet(allowed_set, arg)) {
                return error.ArgumentNotInAllowedSet;
            }

            return FlagArg { .Single = arg };
        },
        else => |needed| {
            var extra = ArrayList([]const u8).init(allocator);
            errdefer extra.deinit();

            var j: usize = 0;
            while (j < needed) : (j += 1) {
                if (*index + 1 >= args.len) {
                    return error.MissingFlagArguments;
                }

                *index += 1;
                const arg = args[*index];

                if (!argInAllowedSet(allowed_set, arg)) {
                    return error.ArgumentNotInAllowedSet;
                }

                try extra.append(arg);
            }

            return FlagArg { .Many = extra };
        },
    }
}

// A store for querying found flags and positional arguments.
pub const Args = struct {
    flags: HashMapFlags,
    positionals: ArrayList([]const u8),

    pub fn parse(allocator: &Allocator, comptime spec: []const Flag, args: []const []const u8) !Args {
        var parsed = Args {
            .flags = HashMapFlags.init(allocator),
            .positionals = ArrayList([]const u8).init(allocator),
        };

        var i: usize = 0;
        next: while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (arg.len != 0 and arg[0] == '-') {
                // TODO: struct/hashmap lookup would be nice here.
                for (spec) |flag| {
                    if (mem.eql(u8, arg, flag.name)) {
                        const flag_name_trimmed = trimStart(flag.name, '-');
                        const flag_args = readFlagArguments(allocator, args, flag.required, flag.allowed_set, &i) catch |err| {
                            switch (err) {
                                error.ArgumentNotInAllowedSet => {
                                    std.debug.warn("argument is invalid for flag: {}\n", arg);
                                    std.debug.warn("allowed options are ");
                                    for (??flag.allowed_set) |possible| {
                                        std.debug.warn("'{}' ", possible);
                                    }
                                    std.debug.warn("\n");
                                },
                                error.MissingFlagArguments => {
                                    std.debug.warn("missing argument for flag: {}\n", arg);
                                },
                                else => {},
                            }

                            return err;
                        };

                        _ = try parsed.flags.put(flag_name_trimmed, flag_args);
                        continue :next;
                    }
                }

                // TODO: Better errors with context, just store a string with the error.
                std.debug.warn("could not match flag: {}\n", arg);
                return error.UnknownFlag;
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
    pub fn single(self: &Args, name: []const u8) ?[]const u8 {
        // TODO: Can we enforce these accesses at compile-time, need to move to a struct instead
        // of a hash-map in that case. Assume the user has handled the required options according
        // to the given spec.
        if (self.flags.get(name)) |entry| {
            switch (entry.value) {
                FlagArg.Single => |inner| { return inner; },
                else => @panic("attempted to retrieve flag with wrong type"),
            }
        } else {
            return null;
        }
    }

    // e.g. --names value1 value2 value3
    pub fn many(self: &Args, name: []const u8) ?[]const []const u8 {
        if (self.flags.get(name)) |entry| {
            switch (entry.value) {
                FlagArg.Many => |inner| { return inner.toSliceConst(); },
                else => @panic("attempted to retrieve flag with wrong type"),
            }
        } else {
            return null;
        }
    }
};

// Arguments for a flag. e.g. --command arg1 arg2.
const FlagArg = union(enum) {
    None,
    Single: []const u8,
    Many: ArrayList([]const u8),
};

// Specification for how a flag should be parsed.
pub const Flag = struct {
    name: []const u8,
    required: usize,
    allowed_set: ?[]const []const u8,

    pub fn Bool(comptime name: []const u8) Flag {
        return ArgN(name, 0);
    }

    pub fn Arg1(comptime name: []const u8) Flag {
        return ArgN(name, 1);
    }

    pub fn ArgN(comptime name: []const u8, comptime n: usize) Flag {
        return Flag {
            .name = name,
            .required = n,
            .allowed_set = null,
        };
    }

    pub fn Option(comptime name: []const u8, comptime set: []const []const u8) Flag {
        return Flag {
            .name = name,
            .required = 1,
            .allowed_set = set,
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
        Flag.Option("color", []const []const u8 { "on", "off", "auto" }),
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
