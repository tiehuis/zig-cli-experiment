# https://ziglang.org/

complete -c zig -f -n '__fish_use_subcommand' -a 'build' -d 'Build project from build.zig'
complete -c zig -f -n '__fish_use_subcommand' -a 'build-exe' -d 'Create executable from source or object files'
complete -c zig -f -n '__fish_use_subcommand' -a 'build-lib' -d 'Create library from source or object files'
complete -c zig -f -n '__fish_use_subcommand' -a 'build-obj' -d 'Create object from source or assembly'
complete -c zig -f -n '__fish_use_subcommand' -a 'cc' -d 'Call the system c compiler and pass args through'
complete -c zig -f -n '__fish_use_subcommand' -a 'fmt' -d 'Parse file and render in canonical zig format'
complete -c zig -f -n '__fish_use_subcommand' -a 'run' -d 'Create executable and run immediately'
complete -c zig -f -n '__fish_use_subcommand' -a 'targets' -d 'List available compilation targets'
complete -c zig -f -n '__fish_use_subcommand' -a 'test' -d 'Create and run a test build'
complete -c zig -f -n '__fish_use_subcommand' -a 'translate' -d 'Convert c code to zig code'
complete -c zig -f -n '__fish_use_subcommand' -a 'version' -d 'Print version number and exit'
complete -c zig -f -n '__fish_use_subcommand' -a 'zen' -d 'Print zen of zig and exit'
