# Bash completion for wattle
# Install: source this file, or place it in /etc/bash_completion.d/wattle
# or ~/.local/share/bash-completion/completions/wattle

_wattle() {
    local cur prev words cword
    _init_completion || return

    local root_flags="-c --color -C --no-color -s --syspath -v --version -h --help"
    local run_flags="-e --eval -l --lib -i --img -r --repl -s --stdin -d --debug -q --quiet"
    local check_flags="-e --lint-error -w --lint-warn -b --bail -h --help"
    local test_flags="-e --lint-error -w --lint-warn -b --bail --seed -f --file -F --no-file -t --test -T --no-test -h --help"
    local levels="none relaxed normal strict all"

    # The subcommand is the first word after the root options. A word that
    # names no subcommand is the start of an implicit run.
    local i=1 sub="" sub_at=0
    while [[ $i -lt $cword ]]; do
        case "${words[i]}" in
            -s|--syspath) ((i += 2)) ;;
            -h|--help|-v|--version|--syspath=*) ((i++)) ;;
            *) break ;;
        esac
    done
    if [[ $i -lt $cword ]]; then
        case "${words[i]}" in
            build|check|help|pkg|run|test) sub="${words[i]}"; sub_at=$i ;;
            *) sub="run"; sub_at=$((i - 1)) ;;
        esac
    fi

    case "$prev" in
        -s|--syspath)
            _filedir -d
            return
            ;;
        -e|--eval)
            if [[ "$sub" == check || "$sub" == test ]]; then
                COMPREPLY=($(compgen -W "$levels" -- "$cur"))
            fi
            return
            ;;
        -w|--lint-warn|--lint-error)
            COMPREPLY=($(compgen -W "$levels" -- "$cur"))
            return
            ;;
        -l|--lib)
            _filedir wattle
            return
            ;;
    esac

    case "$sub" in
        "")
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$root_flags $run_flags" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "build check help pkg run test" -- "$cur"))
                _filedir wattle
            fi
            ;;
        build)
            if [[ $((cword - sub_at)) -eq 1 ]]; then
                COMPREPLY=($(compgen -W "exe img lib" -- "$cur"))
            elif [[ "${words[sub_at + 1]}" == img ]]; then
                if [[ "$cur" == -* ]]; then
                    COMPREPLY=($(compgen -W "-l --lib -h --help" -- "$cur"))
                else
                    _filedir wattle
                fi
            else
                case "$prev" in
                    -r|--release) COMPREPLY=($(compgen -W "safe fast small" -- "$cur")) ;;
                    -t|--target) ;;
                    *)
                        if [[ "$cur" == -* ]]; then
                            COMPREPLY=($(compgen -W "-r --release -t --target -h --help" -- "$cur"))
                        fi
                        ;;
                esac
            fi
            ;;
        check)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$check_flags" -- "$cur"))
            else
                _filedir wattle
            fi
            ;;
        pkg)
            if [[ $((cword - sub_at)) -eq 1 ]]; then
                COMPREPLY=($(compgen -W "install reinstall uninstall update clean list" -- "$cur"))
            else
                case "${words[sub_at + 1]}" in
                    install) _filedir -d ;;
                    reinstall|uninstall)
                        COMPREPLY=($(compgen -W "$("${words[0]}" pkg list 2>/dev/null)" -- "$cur"))
                        ;;
                esac
            fi
            ;;
        run)
            # Once the script is given, every word after it is its argument.
            local j script=""
            for ((j = sub_at + 1; j < cword; j++)); do
                case "${words[j]}" in
                    -e|--eval|-l|--lib) ((j++)) ;;
                    -*) ;;
                    *) script="${words[j]}"; break ;;
                esac
            done
            if [[ -n "$script" ]]; then
                _filedir
            elif [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$run_flags -h --help" -- "$cur"))
            else
                _filedir wattle
            fi
            ;;
        test)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$test_flags" -- "$cur"))
            fi
            ;;
        help)
            case "$((cword - sub_at)):${words[sub_at + 1]}" in
                1:*) COMPREPLY=($(compgen -W "build check pkg run test" -- "$cur")) ;;
                2:build) COMPREPLY=($(compgen -W "exe img lib" -- "$cur")) ;;
                2:pkg) COMPREPLY=($(compgen -W "install reinstall uninstall update clean list" -- "$cur")) ;;
            esac
            ;;
    esac
}

complete -F _wattle wattle
