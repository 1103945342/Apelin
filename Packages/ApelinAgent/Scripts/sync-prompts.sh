#!/usr/bin/env bash
# CI's half of keeping the system prompt's Swift in step with its Markdown:
# regenerate SystemPromptText.swift from Packages/ApelinAgent/Prompts/*.md, so
# the build that follows compiles what the Markdown says, and, when the
# generated file changed and PUSH_TOKEN is set on a push to main, commit it and
# push that commit to main. Without PUSH_TOKEN it only regenerates.
#
# A push made with the workflow's own token starts no workflow, so the commit
# this pushes does not build again. When main has moved on since this run
# checked it out, nothing is pushed: the newer push's run regenerates for itself.
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
generated="Packages/ApelinAgent/Sources/ApelinAgent/Session/SystemPromptText.swift"
cd "$root"

python3 Packages/ApelinAgent/Scripts/embed-prompts.py

# A git that fails stops the script here (set -e): it is never read as a change.
changes="$(git status --porcelain -- "$generated")"
if [[ -z "$changes" ]]; then
    echo "ok: $generated already matches Packages/ApelinAgent/Prompts"
    exit 0
fi
echo "::notice::$generated was regenerated from Packages/ApelinAgent/Prompts"

if [[ -z "${PUSH_TOKEN:-}" ]]; then
    exit 0
fi
if [[ "${GITHUB_EVENT_NAME:-}" != "push" || "${GITHUB_REF:-}" != "refs/heads/main" ]]; then
    echo "not a push to main: the regenerated file is built but not committed"
    exit 0
fi
: "${GITHUB_SERVER_URL:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}"

echo "::add-mask::$PUSH_TOKEN"
auth="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$PUSH_TOKEN" | base64 | tr -d '\n')"
echo "::add-mask::$auth"
remote="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY.git"

git -c "http.extraheader=$auth" fetch --quiet --no-tags "$remote" main
if [[ "$(git rev-parse FETCH_HEAD)" != "$GITHUB_SHA" ]]; then
    echo "::warning::main moved on since $GITHUB_SHA; the regenerated prompt is built but not pushed"
    exit 0
fi

git add -- "$generated"
git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet -m "Agent: regenerate SystemPromptText.swift from Prompts" \
    -m "Written by CI from Packages/ApelinAgent/Prompts/*.md for $GITHUB_SHA."
if git -c "http.extraheader=$auth" push --quiet "$remote" HEAD:refs/heads/main; then
    echo "::notice::pushed $(git rev-parse --short HEAD) with the regenerated prompt to main"
else
    echo "::warning::pushing the regenerated prompt was refused; the build goes on with it"
fi
