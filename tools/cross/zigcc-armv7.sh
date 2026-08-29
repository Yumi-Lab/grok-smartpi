#!/bin/sh
# zig cc wrapper for armv7-unknown-linux-gnueabihf cross builds.
# cc-rs appends its own `--target=armv7-unknown-linux-gnueabihf` (GNU-style triple)
# which zig cc rejects; strip any incoming -target/--target and force ours.
args=""
skip=0
for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
        --target=*) continue ;;
        -target) skip=1; continue ;;
        *) args="$args '$a'" ;;
    esac
done
eval "exec zig cc -target arm-linux-gnueabihf $args"
