# Bash completion for wattle
# Install: source this file, or place it in /etc/bash_completion.d/wattle
# or ~/.local/share/bash-completion/completions/wattle

_wattle() {
    local cur prev words cword
    _init_completion || return

    local flags="-h -v -s -e -E -d -n -N -r -R -p -q -k -m -c -i -l -w -x --"

    case "$prev" in
        -e|-E)
            # Argument is Janet source code — no file completion
            return
            ;;
        -m)
            # syspath: complete directories
            _filedir -d
            return
            ;;
        -c|-l)
            # source file: complete .janet files
            _filedir janet
            return
            ;;
        -w|-x)
            # linting level
            COMPREPLY=($(compgen -W ":none :relaxed :normal :strict" -- "$cur"))
            return
            ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "$flags" -- "$cur"))
        return
    fi

    # Default: complete .janet files and directories
    _filedir janet
}

complete -F _wattle wattle
