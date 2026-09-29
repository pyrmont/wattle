# Fish completion for wattle

# Disable file completion by default; re-enable where a file is expected
complete -c wattle -f

set -l subcommands run check build twig help
set -l twig_verbs install reinstall uninstall update clean list

# A word that is not a subcommand starts an implicit run, so the options of
# run are offered before a subcommand as well as after it.
set -l at_run '__fish_use_subcommand; or __fish_seen_subcommand_from run'

# Root options
complete -c wattle -n __fish_use_subcommand -s h -l help -d 'Show usage and exit'
complete -c wattle -n __fish_use_subcommand -s v -l version -d 'Show version and exit'
complete -c wattle -n __fish_use_subcommand -s m -l syspath -r -d 'Set the system path for modules' -a '(__fish_complete_directories)'

# Subcommands
complete -c wattle -n __fish_use_subcommand -a run -d 'Run a script, evaluate code or start the REPL'
complete -c wattle -n __fish_use_subcommand -a check -d 'Compile a script without running it'
complete -c wattle -n __fish_use_subcommand -a build -d 'Build an artifact from source'
complete -c wattle -n __fish_use_subcommand -a twig -d 'Manage installed bundles'
complete -c wattle -n __fish_use_subcommand -a help -d 'Describe a subcommand'

# run
complete -c wattle -n $at_run -s e -l eval -x -d 'Evaluate a string of Wattle'
complete -c wattle -n $at_run -s l -l lib -r -d 'Use a module before the script'
complete -c wattle -n $at_run -s i -l img -d 'Treat script as an image'
complete -c wattle -n $at_run -s r -l repl -d 'Open the REPL after running'
complete -c wattle -n $at_run -s s -l stdin -d 'Read REPL input as raw lines from stdin'
complete -c wattle -n $at_run -s d -l debug -d 'Enable debug mode'
complete -c wattle -n $at_run -s q -l quiet -d 'Hide the logo in the REPL'
complete -c wattle -n $at_run -s c -l color -d 'Enable ANSI colour'
complete -c wattle -n $at_run -s C -l no-color -d 'Disable ANSI colour'
complete -c wattle -n '__fish_seen_subcommand_from run' -s h -l help -d 'Show usage and exit'
complete -c wattle -n $at_run -F

# check
complete -c wattle -n '__fish_seen_subcommand_from check' -s e -l lint-error -x -d 'Set the lint error level' -a 'none relaxed normal strict all'
complete -c wattle -n '__fish_seen_subcommand_from check' -s w -l lint-warn -x -d 'Set the lint warning level' -a 'none relaxed normal strict all'
complete -c wattle -n '__fish_seen_subcommand_from check' -s b -l bail -d 'Stop at the first error'
complete -c wattle -n '__fish_seen_subcommand_from check' -s h -l help -d 'Show usage and exit'
complete -c wattle -n '__fish_seen_subcommand_from check' -F

# build
complete -c wattle -n '__fish_seen_subcommand_from build; and not __fish_seen_subcommand_from img' -a img -d 'Compile a source file into an image'
complete -c wattle -n '__fish_seen_subcommand_from img' -s l -l lib -r -d 'Use a module before the source'
complete -c wattle -n '__fish_seen_subcommand_from img' -s h -l help -d 'Show usage and exit'
complete -c wattle -n '__fish_seen_subcommand_from img' -F

# twig
complete -c wattle -n "__fish_seen_subcommand_from twig; and not __fish_seen_subcommand_from $twig_verbs" -a install -d 'Install a bundle from a directory'
complete -c wattle -n "__fish_seen_subcommand_from twig; and not __fish_seen_subcommand_from $twig_verbs" -a reinstall -d 'Reinstall a bundle by name'
complete -c wattle -n "__fish_seen_subcommand_from twig; and not __fish_seen_subcommand_from $twig_verbs" -a uninstall -d 'Uninstall a bundle by name'
complete -c wattle -n "__fish_seen_subcommand_from twig; and not __fish_seen_subcommand_from $twig_verbs" -a update -d 'Reinstall all installed bundles'
complete -c wattle -n "__fish_seen_subcommand_from twig; and not __fish_seen_subcommand_from $twig_verbs" -a clean -d 'Uninstall all orphaned bundles'
complete -c wattle -n "__fish_seen_subcommand_from twig; and not __fish_seen_subcommand_from $twig_verbs" -a list -d 'List all installed bundles'
complete -c wattle -n '__fish_seen_subcommand_from install' -a '(__fish_complete_directories)'
complete -c wattle -n '__fish_seen_subcommand_from reinstall uninstall' -a '(wattle twig list 2>/dev/null)'

# help
complete -c wattle -n '__fish_seen_subcommand_from help; and not __fish_seen_subcommand_from run check build twig' -a 'run check build twig'
complete -c wattle -n '__fish_seen_subcommand_from help; and __fish_seen_subcommand_from build' -a img
complete -c wattle -n '__fish_seen_subcommand_from help; and __fish_seen_subcommand_from twig' -a "$twig_verbs"
