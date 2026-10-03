#compdef wattle

# Zsh completion for wattle

_wattle_run_options() {
    _arguments -s \
        '(- *)'{-h,--help}'[Show usage and exit]' \
        '*'{-e+,--eval=}'[Evaluate a string of Wattle]:code:' \
        '*'{-l+,--lib=}'[Use a module before the script]:module:_files -g "*.wattle"' \
        '(-i --img)'{-i,--img}'[Treat script as an image]' \
        '(-r --repl)'{-r,--repl}'[Open the REPL after running]' \
        '--seed=[Seed the shuffle of the tests]:seed:' \
        '(-s --stdin)'{-s,--stdin}'[Read REPL input as raw lines from stdin]' \
        '(-d --debug)'{-d,--debug}'[Enable debug mode]' \
        '(-q --quiet)'{-q,--quiet}'[Hide the logo in the REPL]' \
        '1:script:_files' \
        '*:script argument:_files'
}

_wattle_check_options() {
    _arguments -s \
        '(- *)'{-h,--help}'[Show usage and exit]' \
        '(-e --lint-error)'{-e+,--lint-error=}'[Set the lint error level]:level:(none relaxed normal strict all)' \
        '(-w --lint-warn)'{-w+,--lint-warn=}'[Set the lint warning level]:level:(none relaxed normal strict all)' \
        '(-b --bail)'{-b,--bail}'[Stop at the first error]' \
        '1:script:_files -g "*.wattle"'
}

_wattle_test_options() {
    _arguments -s \
        '(- *)'{-h,--help}'[Show usage and exit]' \
        '(-e --lint-error)'{-e+,--lint-error=}'[Set the lint error level]:level:(none relaxed normal strict all)' \
        '(-w --lint-warn)'{-w+,--lint-warn=}'[Set the lint warning level]:level:(none relaxed normal strict all)' \
        '(-b --bail)'{-b,--bail}'[Stop after the first failing test file]' \
        '--seed=[Seed the shuffle of the tests]:seed:' \
        '*'{-f+,--file=}'[Run only a test file]:path:_files -g "*.wattle"' \
        '*'{-F+,--no-file=}'[Do not run a test file]:path:_files -g "*.wattle"' \
        '*'{-t+,--test=}'[Run only a named test]:name:' \
        '*'{-T+,--no-test=}'[Do not run a named test]:name:'
}

_wattle() {
    local curcontext="$curcontext" state state_descr line ret=1
    typeset -A opt_args
    local -a subcommands
    subcommands=(
        'build:Build an artifact from source'
        'check:Compile a script without running it'
        'help:Describe a subcommand'
        'pkg:Manage installed packages'
        'run:Run a script, evaluate code or start the REPL'
        'test:Run the tests in ./test'
    )

    _arguments -C -s \
        '(-c --color -C --no-color)'{-c,--color}'[Enable ANSI colour]' \
        '(-c --color -C --no-color)'{-C,--no-color}'[Disable ANSI colour]' \
        '(-p --prefix)'{-p+,--prefix=}'[Set the prefix for modules]:path:_directories' \
        '(- *)'{-v,--version}'[Show version and exit]' \
        '(- *)'{-h,--help}'[Show usage and exit]' \
        '*'{-e+,--eval=}'[Evaluate a string of Wattle]:code:' \
        '*'{-l+,--lib=}'[Use a module before the script]:module:_files -g "*.wattle"' \
        '(-i --img)'{-i,--img}'[Treat script as an image]' \
        '(-r --repl)'{-r,--repl}'[Open the REPL after running]' \
        '(-s --stdin)'{-s,--stdin}'[Read REPL input as raw lines from stdin]' \
        '(-d --debug)'{-d,--debug}'[Enable debug mode]' \
        '(-q --quiet)'{-q,--quiet}'[Hide the logo in the REPL]' \
        '1: :->subcommand' \
        '*:: :->args' && ret=0

    case $state in
        subcommand)
            _describe -t subcommands 'subcommand' subcommands && ret=0
            _files -g "*.wattle" && ret=0
            ;;
        args)
            case $line[1] in
                b|build)
                    if (( CURRENT == 2 )); then
                        _values 'target' \
                            'exe[Build the executables that info.edn declares]' \
                            'img[Compile a source file into an image]' \
                            'lib[Build the native modules that info.edn declares]' \
                            'web[Build the web programs that info.edn declares]' && ret=0
                    else
                        local target=$words[2]
                        shift 2 words
                        (( CURRENT -= 2 ))
                        case $target in
                            img)
                                _arguments -s \
                                    '(- *)'{-h,--help}'[Show usage and exit]' \
                                    '*'{-l+,--lib=}'[Use a module before the source]:module:_files -g "*.wattle"' \
                                    '1:source:_files -g "*.wattle"' \
                                    '2:output:_files' && ret=0
                                ;;
                            exe|lib)
                                _arguments -s \
                                    '(- *)'{-h,--help}'[Show usage and exit]' \
                                    '(-r --release)'{-r+,--release=}'[Optimise for safe, fast or small]:mode:(safe fast small)' \
                                    '(-t --target)'{-t+,--target=}'[Build for a Zig target triple]:triple:' \
                                    '1:name:' && ret=0
                                ;;
                            web)
                                _arguments -s \
                                    '(- *)'{-h,--help}'[Show usage and exit]' \
                                    '(-r --release)'{-r+,--release=}'[Optimise for safe, fast or small]:mode:(safe fast small)' \
                                    '1:name:' && ret=0
                                ;;
                        esac
                    fi
                    ;;
                c|check)
                    shift words
                    (( CURRENT-- ))
                    _wattle_check_options && ret=0
                    ;;
                p|pkg)
                    if (( CURRENT == 2 )); then
                        _values 'verb' \
                            'install[Install a package from a directory, tarball or Git repository]' \
                            'reinstall[Reinstall a package by name]' \
                            'uninstall[Uninstall a package by name]' \
                            'update[Reinstall all installed packages]' \
                            'clean[Uninstall all orphaned packages]' \
                            'list[List all installed packages]' && ret=0
                    else
                        case $line[2] in
                            install) _directories && ret=0 ;;
                            reinstall|uninstall)
                                local -a packages
                                packages=(${(f)"$(${words[1]} pkg list 2>/dev/null)"})
                                _describe -t packages 'package' packages && ret=0
                                ;;
                        esac
                    fi
                    ;;
                r|run)
                    shift words
                    (( CURRENT-- ))
                    _wattle_run_options && ret=0
                    ;;
                t|test)
                    shift words
                    (( CURRENT-- ))
                    _wattle_test_options && ret=0
                    ;;
                h|help)
                    case "$CURRENT:$line[2]" in
                        2:*) _describe -t subcommands 'subcommand' subcommands && ret=0 ;;
                        3:(b|build)) _values 'target' exe img lib && ret=0 ;;
                        3:(p|pkg)) _values 'verb' install reinstall uninstall update clean list && ret=0 ;;
                    esac
                    ;;
                *)
                    # An implicit run: the first word is the script.
                    _files && ret=0
                    ;;
            esac
            ;;
    esac

    return ret
}

_wattle "$@"
