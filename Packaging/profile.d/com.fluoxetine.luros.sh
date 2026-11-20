# Apelin's terminal starts its shell with the project's toolchain first on
# PATH and names it in APELIN_TOOLCHAIN_BIN, and names itself in
# APELIN_TERMINAL. A login shell's /etc/profile sets PATH and the prompt anew,
# then reads this folder: put the toolchain back in front, and shorten the
# prompt — the folder, then the shell's own `$` or `#` — because that
# profile's `\w` is the whole path on every line. Anywhere else these are
# unset and this does nothing, and a user's own ~/.bash_profile and ~/.bashrc
# are read after this, so a prompt they set there still wins.
if [ -n "${APELIN_TOOLCHAIN_BIN:-}" ] && [ -d "$APELIN_TOOLCHAIN_BIN" ]; then
    case ":$PATH:" in
        *":$APELIN_TOOLCHAIN_BIN:"*) ;;
        *) PATH="$APELIN_TOOLCHAIN_BIN:$PATH"; export PATH ;;
    esac
fi

# Only bash is spoken to: `\W` and `\$` are its own, and a `sh` that is not
# bash would print them as written. `\W` is the folder the shell is in (`~`
# at home), which is what the reader needs to see; the whole path is a `pwd`
# away.
if [ -n "${APELIN_TERMINAL:-}" ] && [ -n "${BASH_VERSION:-}" ]; then
    PS1='\W \$ '
    export PS1
fi
