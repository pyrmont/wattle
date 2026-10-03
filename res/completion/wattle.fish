# Fish completion for wattle

# Disable file completion by default; re-enable where a file is expected
complete -c wattle -f

set -l subcommands build b check c help h pkg p run r test t
set -l pkg_verbs install reinstall uninstall update clean list

# A word that is not a subcommand starts an implicit run, so the options of
# run are offered before a subcommand as well as after it.
set -l at_run '__fish_use_subcommand; or __fish_seen_subcommand_from run r'

# Root options
complete -c wattle -n __fish_use_subcommand -s c -l color -d 'Enable ANSI colour'
complete -c wattle -n __fish_use_subcommand -s C -l no-color -d 'Disable ANSI colour'
complete -c wattle -n __fish_use_subcommand -s p -l prefix -r -d 'Set the prefix for modules' -a '(__fish_complete_directories)'
complete -c wattle -n __fish_use_subcommand -s v -l version -d 'Show version and exit'
complete -c wattle -n __fish_use_subcommand -s h -l help -d 'Show usage and exit'

# Subcommands
complete -c wattle -n __fish_use_subcommand -a build -d 'Build an artifact from source'
complete -c wattle -n __fish_use_subcommand -a check -d 'Compile a script without running it'
complete -c wattle -n __fish_use_subcommand -a pkg -d 'Manage installed packages'
complete -c wattle -n __fish_use_subcommand -a run -d 'Run a script, evaluate code or start the REPL'
complete -c wattle -n __fish_use_subcommand -a test -d 'Run the tests in ./test'
complete -c wattle -n __fish_use_subcommand -a help -d 'Describe a subcommand'

# build
complete -c wattle -n '__fish_seen_subcommand_from build b; and not __fish_seen_subcommand_from exe img lib web' -a exe -d 'Build the executables that info.edn declares'
complete -c wattle -n '__fish_seen_subcommand_from build b; and not __fish_seen_subcommand_from exe img lib web' -a img -d 'Compile a source file into an image'
complete -c wattle -n '__fish_seen_subcommand_from build b; and not __fish_seen_subcommand_from exe img lib web' -a lib -d 'Build the native modules that info.edn declares'
complete -c wattle -n '__fish_seen_subcommand_from build b; and not __fish_seen_subcommand_from exe img lib web' -a web -d 'Build the web programs that info.edn declares'
complete -c wattle -n '__fish_seen_subcommand_from exe lib' -s r -l release -x -a 'safe fast small' -d 'Optimise for safe, fast or small'
complete -c wattle -n '__fish_seen_subcommand_from exe lib' -s t -l target -x -d 'Build for a Zig target triple'
complete -c wattle -n '__fish_seen_subcommand_from exe lib' -s h -l help -d 'Show usage and exit'
complete -c wattle -n '__fish_seen_subcommand_from web' -s r -l release -x -a 'safe fast small' -d 'Optimise for safe, fast or small'
complete -c wattle -n '__fish_seen_subcommand_from web' -s h -l help -d 'Show usage and exit'
complete -c wattle -n '__fish_seen_subcommand_from img' -s l -l lib -r -d 'Use a module before the source'
complete -c wattle -n '__fish_seen_subcommand_from img' -s h -l help -d 'Show usage and exit'
complete -c wattle -n '__fish_seen_subcommand_from img' -F

# check
complete -c wattle -n '__fish_seen_subcommand_from check c' -s e -l lint-error -x -d 'Set the lint error level' -a 'none relaxed normal strict all'
complete -c wattle -n '__fish_seen_subcommand_from check c' -s w -l lint-warn -x -d 'Set the lint warning level' -a 'none relaxed normal strict all'
complete -c wattle -n '__fish_seen_subcommand_from check c' -s b -l bail -d 'Stop at the first error'
complete -c wattle -n '__fish_seen_subcommand_from check c' -s h -l help -d 'Show usage and exit'
complete -c wattle -n '__fish_seen_subcommand_from check c' -F

# pkg
complete -c wattle -n "__fish_seen_subcommand_from pkg p; and not __fish_seen_subcommand_from $pkg_verbs" -a install -d 'Install a package from a directory, tarball or Git repository'
complete -c wattle -n "__fish_seen_subcommand_from pkg p; and not __fish_seen_subcommand_from $pkg_verbs" -a reinstall -d 'Reinstall a package by name'
complete -c wattle -n "__fish_seen_subcommand_from pkg p; and not __fish_seen_subcommand_from $pkg_verbs" -a uninstall -d 'Uninstall a package by name'
complete -c wattle -n "__fish_seen_subcommand_from pkg p; and not __fish_seen_subcommand_from $pkg_verbs" -a update -d 'Reinstall all installed packages'
complete -c wattle -n "__fish_seen_subcommand_from pkg p; and not __fish_seen_subcommand_from $pkg_verbs" -a clean -d 'Uninstall all orphaned packages'
complete -c wattle -n "__fish_seen_subcommand_from pkg p; and not __fish_seen_subcommand_from $pkg_verbs" -a list -d 'List all installed packages'
complete -c wattle -n '__fish_seen_subcommand_from install' -a '(__fish_complete_directories)'
complete -c wattle -n '__fish_seen_subcommand_from reinstall uninstall' -a '(wattle pkg list 2>/dev/null)'

# run
complete -c wattle -n $at_run -s e -l eval -x -d 'Evaluate a string of Wattle'
complete -c wattle -n $at_run -s l -l lib -r -d 'Use a module before the script'
complete -c wattle -n $at_run -s i -l img -d 'Treat script as an image'
complete -c wattle -n $at_run -s r -l repl -d 'Open the REPL after running'
complete -c wattle -n $at_run -s s -l stdin -d 'Read REPL input as raw lines from stdin'
complete -c wattle -n $at_run -s d -l debug -d 'Enable debug mode'
complete -c wattle -n $at_run -s q -l quiet -d 'Hide the logo in the REPL'
complete -c wattle -n '__fish_seen_subcommand_from run r' -s h -l help -d 'Show usage and exit'
complete -c wattle -n $at_run -F

# test
complete -c wattle -n '__fish_seen_subcommand_from test t' -s e -l lint-error -x -d 'Set the lint error level' -a 'none relaxed normal strict all'
complete -c wattle -n '__fish_seen_subcommand_from test t' -s w -l lint-warn -x -d 'Set the lint warning level' -a 'none relaxed normal strict all'
complete -c wattle -n '__fish_seen_subcommand_from test t' -s b -l bail -d 'Stop after the first failing test file'
complete -c wattle -n '__fish_seen_subcommand_from test t' -l seed -x -d 'Seed the shuffle of the tests'
complete -c wattle -n '__fish_seen_subcommand_from test t' -s f -l file -r -d 'Run only a test file'
complete -c wattle -n '__fish_seen_subcommand_from test t' -s F -l no-file -r -d 'Do not run a test file'
complete -c wattle -n '__fish_seen_subcommand_from test t' -s t -l test -x -d 'Run only a named test'
complete -c wattle -n '__fish_seen_subcommand_from test t' -s T -l no-test -x -d 'Do not run a named test'
complete -c wattle -n '__fish_seen_subcommand_from test t' -s h -l help -d 'Show usage and exit'

# help
complete -c wattle -n '__fish_seen_subcommand_from help h; and not __fish_seen_subcommand_from build b check c pkg p run r test t' -a 'build check pkg run test'
complete -c wattle -n '__fish_seen_subcommand_from help h; and __fish_seen_subcommand_from build b' -a 'exe img lib web'
complete -c wattle -n '__fish_seen_subcommand_from help h; and __fish_seen_subcommand_from pkg p' -a "$pkg_verbs"
