#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <project-name>" >&2
    exit 1
fi

project_name=$1
case "$project_name" in
    "" | . | .. | */*)
        echo "project name must be a single directory name" >&2
        exit 1
        ;;
esac

starter_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
codehub_root=$(dirname -- "$starter_root")
target="$codehub_root/$project_name"

if [ -e "$target" ]; then
    echo "destination already exists: $target" >&2
    exit 1
fi

command -v rsync >/dev/null 2>&1 || {
    echo "rsync is required" >&2
    exit 1
}
command -v git >/dev/null 2>&1 || {
    echo "git is required" >&2
    exit 1
}

rsync -a \
    --exclude='.git' \
    --exclude='out' \
    --exclude='cache' \
    --exclude='broadcast' \
    --exclude='.devnet' \
    --exclude='reports' \
    --exclude='ui/dist' \
    "$starter_root/" \
    "$target/"

git -C "$target" init
git -C "$target" add .
git -C "$target" commit -m "chore: initialize from v4hook starter"

echo "created $target"
