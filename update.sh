#!/usr/bin/env bash
set -euo pipefail

red=$'\e[31m'
yellow=$'\e[33m'
green=$'\e[32m'
cyan=$'\e[36m'
gray=$'\e[90m'
bold=$'\e[1m'
white=$'\e[0m'

engine=tmt/engine
runtime=tmt/runtime

fail() { printf '%s\n' "$red" "$*" "$white" >&2; exit 1; }
confirm() { local answer; read -r -p "$1 [y/N] " answer && [[ $answer == [yY] ]]; }

safe() {
    [[ -z $(git -C "$1" status --porcelain) ]] || fail "$1 has local changes!"
    [[ -z $(git -C "$1" rev-list -1 HEAD --not --remotes=origin) ]] || fail "$1 has local commits!"
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project=${1:-$(git -C "$script_dir" rev-parse --show-superproject-working-tree)}
[[ -n $project ]] || fail 'The updater should run from within a TMT mod!'
cd "$project"

branch=$(git config -f .gitmodules --get "submodule.$engine.branch" || true)
[[ $branch == stable || $branch == beta ]] || fail 'Engine branch must be stable or beta!'

git submodule sync --quiet -- "$engine" "$runtime"

for path in "$engine" "$runtime"; do
    [[ -e $path/.git ]] || git submodule update --init --checkout -- "$path"
    git -C "$path" fetch --prune --tags origin
    safe "$path"
done

installed=$(git -C "$engine" describe --tags --exact-match)
engine_before=$(git -C "$engine" rev-parse HEAD)
runtime_before=$(git -C "$runtime" rev-parse HEAD)
runtime_target=$(git -C "$runtime" rev-parse --verify -q origin/main) ||
    fail 'Runtime has no main branch (what?)'

printf '\n%sInstalled: %s %s(%s)\n' "$bold" "$installed" "$white" "$branch"

for release_branch in stable beta; do
    if version=$(git -C "$engine" describe --tags --exact-match "origin/$release_branch" 2>/dev/null); then
        printf '%s%s: %s%s\n' "$cyan" "$release_branch" "$version" "$white"
    else
        printf '%s: none\n' "$release_branch"
    fi
done

other=beta
[[ $branch == beta ]] && other=stable

printf '\n1. Update %s\n%s2. Switch to %s\n3. Install a specific version%s\n\n' \
    "$branch" "$gray" "$other" "$white"

read -r -p 'Choose [1-3]: ' choice || exit 0

selected_branch=$branch

case $choice in
    1)
        target_ref="origin/$branch"
        ;;
    2)
        selected_branch=$other
        target_ref="origin/$other"
        ;;
    3)
        read -r -p 'Version: ' version || exit 0
        target_ref="refs/tags/$version"
        ;;
    '')
        echo 'Cancelled.'
        exit 0
        ;;
    *)
        fail 'Choose 1, 2, or 3.'
        ;;
esac

target=$(git -C "$engine" rev-parse --verify -q "$target_ref") ||
    fail 'Release not found! (does it exist?)'

if [[ $choice == 1 && $engine_before == "$target" && $runtime_before == "$runtime_target" ]]; then
    printf '\n%sAlready up to date!%s\n' "$green" "$white"
    exit 0
fi

target_version=$(git -C "$engine" describe --tags --exact-match "$target")

printf '\nEngine: %s -> %s\nBranch: %s -> %s\n' \
    "$installed" "$target_version" \
    "$branch" "$selected_branch"

if [[ $runtime_before != "$runtime_target" ]]; then
    printf 'Runtime: %s -> %s\n' \
        "${runtime_before:0:12}" "${runtime_target:0:12}"
fi

printf '\n'

if [[ $target_version == *-beta.* && ( $branch != beta || $installed != *-beta.* ) ]]; then
    printf '%sWarning: the beta branch is intended for those who want to test TMT and may experience unexpected bugs.%s\n' "$yellow" "$white"
fi

if [[ $installed != "$target_version" ]]; then
    newest=$(git -C "$engine" -c versionsort.suffix=-beta tag \
        --sort=-version:refname --list "$installed" "$target_version" | head -n1)

    [[ $newest != "$installed" ]] || printf "%sWarning: this is an engine downgrade! I hope you know what you're doing.%s\n" "$yellow" "$white"
fi

confirm 'Apply?' || {
    echo 'Cancelled!'
    exit 0
}

git -C "$engine" checkout --detach --no-overwrite-ignore --quiet "$target"
git -C "$runtime" checkout --detach --no-overwrite-ignore --quiet "$runtime_target"

[[ $selected_branch == "$branch" ]] ||
    git submodule set-branch --branch "$selected_branch" -- "$engine"

printf '\n%sUpdated engine to %s%s.\n' \
    "$green" "$target_version" "$white"

if [[ $runtime_before != "$runtime_target" ]]; then
    printf '%sUpdated runtime to %s%s.\n' \
        "$green" "${runtime_target:0:12}" "$white"
fi

printf 'Release notes: https://github.com/TheModdingTree/tmt-engine-dist/releases/tag/%s\n' "$target_version"

echo 'Make sure your mod still works, then make sure to commit the update!'