# Shell completions for Wattle

This directory contains shell completion scripts for the `wattle` interpreter.

## Bash

```sh
# Temporary (current session only)
source /path/to/wattle.bash

# Permanent (system-wide)
sudo cp wattle.bash /etc/bash_completion.d/wattle

# Permanent (user only)
cp wattle.bash ~/.local/share/bash-completion/completions/wattle
```

## Zsh

```sh
# Copy to a directory in your $fpath, e.g.:
cp wattle.zsh ~/.zsh/completions/_wattle

# Ensure the directory is in $fpath (add to ~/.zshrc if needed):
# fpath=(~/.zsh/completions $fpath)
# autoload -Uz compinit && compinit
```

## Fish

```sh
cp wattle.fish ~/.config/fish/completions/wattle.fish
```
