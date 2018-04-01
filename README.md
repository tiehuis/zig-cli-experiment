Experimenting with how we can structure the cli of the zig compiler and its
associated sub-commands.

The current method is quite unwieldy and I'd like to see a clean implementation
for the self-hosted compiler.

We will probably pull out any useful argument parsing into a library/file maybe
in std depending on if its useful enough.
