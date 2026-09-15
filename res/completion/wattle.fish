# Fish completion for wattle

# Disable file completion by default; re-enable for specific flags
complete -c wattle -f

# Flags
complete -c wattle -s h -d 'Show usage and exit'
complete -c wattle -s v -d 'Show version and exit'
complete -c wattle -s s -d 'Read raw stdin (no readline features)'
complete -c wattle -s e -r -d 'Execute Janet source string'
complete -c wattle -s E -r -d 'Execute Janet expression as short-fn with remaining args'
complete -c wattle -s d -d 'Enable debug mode'
complete -c wattle -s n -d 'Disable ANSI colors in REPL'
complete -c wattle -s N -d 'Enable ANSI colors in REPL'
complete -c wattle -s r -d 'Open REPL after executing sources'
complete -c wattle -s R -d 'Disable loading user profile in REPL'
complete -c wattle -s p -d 'Persistent mode (continue after errors)'
complete -c wattle -s q -d 'Hide logo in REPL'
complete -c wattle -s k -d 'Compile only (lint), do not execute'
complete -c wattle -s i -d 'Treat script as a .jimage file'
complete -c wattle -s m -r -d 'Set syspath for module loading' -a '(__fish_complete_directories)'
complete -c wattle -s c -r -d 'Precompile source to .jimage'
complete -c wattle -s l -r -d 'Import module before script/REPL' -a '(find . -name "*.janet" -printf "%f\n" 2>/dev/null)'
complete -c wattle -s w -r -d 'Set warning linting level' -a ':none :relaxed :normal :strict'
complete -c wattle -s x -r -d 'Set error linting level' -a ':none :relaxed :normal :strict'

# File arguments: .janet files and directories
complete -c wattle -F -a '*.janet'
