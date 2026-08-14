#!/usr/bin/env bash
#
# Publish inst/js/survey-timing.js to the `prod` branch, which GitHub Pages
# serves at
#
#   https://canadian-municipal-barometer.github.io/response-time-tools/survey-timing.js
#
# `main` is the source of truth; `prod` holds only what Pages needs to serve
# and is never edited by hand. Publishing is a deliberate step rather than
# something a push to `main` does for you: live surveys re-fetch this file on
# every page, so an unfinished commit on `main` must not be able to reach
# respondents mid-fielding.
#
# Usage: tools/publish.sh [-m "commit message"]
set -euo pipefail

branch=prod
message=""

while getopts ":m:" opt; do
  case "$opt" in
    m) message=$OPTARG ;;
    *) echo "usage: tools/publish.sh [-m message]" >&2; exit 2 ;;
  esac
done

repo_root=$(git rev-parse --show-toplevel)
src="$repo_root/inst/js/survey-timing.js"

[ -f "$src" ] || { echo "error: $src not found" >&2; exit 1; }

# Never publish a file that won't parse -- a syntax error here breaks data
# collection for every respondent on the survey.
if command -v node >/dev/null 2>&1; then
  node --check "$src"
else
  echo "warning: node not found, skipping syntax check" >&2
fi

head_sha=$(git -C "$repo_root" rev-parse --short HEAD)
if ! git -C "$repo_root" diff --quiet -- "$src"; then
  echo "warning: $src has uncommitted changes; publishing the working copy" >&2
fi

work=$(mktemp -d)/prod
cleanup() {
  git -C "$repo_root" worktree remove --force "$work" >/dev/null 2>&1 || true
  rm -rf "$(dirname "$work")"
}
trap cleanup EXIT

git -C "$repo_root" fetch --quiet origin "$branch" 2>/dev/null || true

if git -C "$repo_root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  git -C "$repo_root" worktree add --quiet -B "$branch" "$work" "origin/$branch"
else
  # First publish: `prod` is an orphan, so it carries none of the R package's
  # history or files -- only the assets Pages serves.
  git -C "$repo_root" worktree add --quiet --detach "$work"
  git -C "$work" checkout --quiet --orphan "$branch"
  git -C "$work" rm -rqf . >/dev/null 2>&1 || true
fi

cp "$src" "$work/survey-timing.js"

cat > "$work/README.md" <<EOF
# response-time-tools -- published assets

Generated branch. Do not edit by hand: it is overwritten by \`tools/publish.sh\`
on [main](https://github.com/canadian-municipal-barometer/response-time-tools).

GitHub Pages serves this branch, so \`survey-timing.js\` is loadable from a
Qualtrics survey header:

\`\`\`html
<script src="https://canadian-municipal-barometer.github.io/response-time-tools/survey-timing.js"></script>
\`\`\`
EOF

git -C "$work" add -A

if git -C "$work" diff --cached --quiet; then
  echo "prod is already up to date with $head_sha; nothing to publish"
  exit 0
fi

git -C "$work" commit --quiet -m "${message:-publish survey-timing.js from main@$head_sha}"
git -C "$work" push --quiet origin "$branch"

echo "published survey-timing.js (main@$head_sha) to $branch"
echo "https://canadian-municipal-barometer.github.io/response-time-tools/survey-timing.js"
echo "note: GitHub Pages caches for ~10 minutes; add ?v=N to the URL to bust it"
