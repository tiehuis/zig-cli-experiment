const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

pub fn Args(comptime FlagSpec: type) type {
    return struct {
        const Self = this;

        flags: FlagSpec,
        // Could expose a []const []const u8 directly since we don't want modifiable.
        positionals: ArrayList([]const u8),

        pub fn parse(allocator: &Allocator, args: []const []const u8) !Self {
            var self = Self {
                .flags = undefined,
                .positionals = ArrayList([]const u8).init(allocator),
            };

            // zero-initialize flags entry by field, either false or null.

            next: for (args) |arg| {
                if (mem.eql(u8, "--", arg[0..2])) {
                    for (@fieldsOf(FlagSpec)) |field| {
                        // note: transform name at compile-time '_' -> '-'

                        if (mem.eql(u8, arg[2..], field.name)) {
                            // need lookup by string (see #383).
                            switch (field.type) {
                                ?bool => {
                                    parsed.flags[field.name] = true;
                                },
                                ?[]const u8 => {
                                    parsed.flags[field.name] = try nextPositional();
                                },
                                // multi-positional argument
                                else => {},
                            }
                        }

                        continue :next;
                    }

                    // TODO: Better errors with context
                    return error.UnknownArgument;
                } else {
                    try parsed.positionals.append(arg);
                }
            }

            return parsed;
        }

        pub fn deinit(self: &Self) {
            self.positionals.deinit();
        }
    }
}

test "example" {
    const flag_spec = struct {
        help:             ?bool,
        init:             ?bool,
        build_file:       ?[]const u8,
        cache_dir:        ?[]const u8,
        verbose:          ?bool,
        prefix:           ?[]const u8,
        build_file:       ?[]const u8,
        cache_dir:        ?[]const u8,
        verbose_tokenize: ?bool,
        verbose_ast:      ?bool,
        verbose_link:     ?bool,
        verbose_ir:       ?bool,
        verbose_llvm_ir:  ?bool,
        verbose_cimport:  ?bool,
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

    var arguments = try Args(flag_spec).parse(std.debug.global_allocator, cliargs);

    const flags = arguments.flags;
    const positionals = arguments.positionals;

    std.debug.warn("help: {}\n", flags.help)
    std.debug.warn("init: {}\n", flags.init)

    // Compile-error to access a non-specified flag
    // std.debug.warn("init2: {}\n", flags.init2)

    const fallback = flags.build ?? "build.zig"
}
