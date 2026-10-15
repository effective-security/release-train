#!/usr/bin/env bash
# Weekly dependency "release train" for interdependent Go modules.
#
# For each repo, in dependency order (upstream first):
#   1. go get -u, then pin our own modules to the tags created earlier in this run
#   2. run the repo's own check (default `make all`: installs the tools and starts
#      the docker / softhsm environment the tests need, then runs covtest)
#   3. open a PR, wait for CI including the required checks; stop the whole train if it fails
#   4. squash-merge and tag the merge commit the way the repos' SetTag workflow does:
#      $(cat .VERSION).$(git rev-list --count HEAD), e.g. v1.0.312
#
# Env:
#   OWNER            GitHub org that owns the repos (default: effective-security)
#   REPOS            space-separated repo names, upstream first (default: see below)
#   GH_TOKEN         token with contents + pull-requests + issues write on all repos;
#                    with MERGE_ADMIN=1 its user must be an admin of the repos
#   BASE_BRANCH      default: main
#   CHECK            command run in each clone before opening the PR (default: make all);
#                    set it empty to skip. CHECK_<repo> overrides it for one repo,
#                    e.g. CHECK_xdb="make tools generate build test"
#   REQUIRED_CHECKS  comma-separated checks that must pass on the PR, on top of the
#                    branch protection ones (default: UnitTest)
#   CI_TIMEOUT       minutes to wait for the PR checks (default: 90)
#   MERGE_ADMIN      1 = merge with --admin, which skips the required review
#   START_FROM       skip the repos before this one, to resume a train that stopped
#   DRY_RUN          1 = upgrade and run CHECK locally only: no push, PR, tag or issue
#   RELEASE_UNTAGGED 1 = tag a repo with nothing to upgrade when its branch has untagged
#                    commits and green CI, so downstream repos get them
#   KEEP_WORK        1 = keep the clones after a successful run (always kept on failure)
#   WAIT_TAG_CI      1 = also wait for the workflow triggered by the new tag
#   RUN_URL          link to this run, put in PRs and failure issues
set -euo pipefail

OWNER="${OWNER:-effective-security}"
read -r -a REPOS <<< "${REPOS:-xlog x xdb metrics xpki porto gogentic}"
BASE_BRANCH="${BASE_BRANCH:-main}"
CHECK="${CHECK-make all}"
CI_TIMEOUT="${CI_TIMEOUT:-90}"
DRY_RUN="${DRY_RUN:-0}"
BRANCH_PREFIX="deps/weekly-"
BRANCH="$BRANCH_PREFIX$(date -u +%Y%m%d)"
TITLE="chore(deps): weekly dependency update"
WORK="$(mktemp -d)"
declare -A NEWTAG=()   # module path -> tag created in this run
RESULTS=()             # one line per repo for the summary
TAG=""                 # set by release()

compose_down() {  # $1 dir: stop the docker compose projects started from it (by `make all`)
  command -v docker >/dev/null || return 0
  local p
  for p in $(docker compose ls -a --format json 2>/dev/null \
               | jq -r --arg d "$1/" '.[]? | select(.ConfigFiles | contains($d)) | .Name'); do
    docker compose -p "$p" down -v --remove-orphans >/dev/null 2>&1 || true
  done
}

finish() {
  local rc=$?
  cd /
  compose_down "$WORK"
  if (( ${#RESULTS[@]} )); then
    printf '%s\n' "## Dependency train" "" "${RESULTS[@]/#/- }" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
  fi
  if (( rc == 0 )) && [[ ${KEEP_WORK:-0} != 1 ]]; then
    rm -rf "$WORK" 2>/dev/null || true   # containers may leave root-owned files behind
  else
    echo "Clones kept in $WORK"
  fi
}
trap finish EXIT

fail() {  # $1 repo, $2 message: report it on the repo's tracking issue and stop the train
  RESULTS+=("$1: **failed**: $2")
  echo "::error::$1: $2"
  if [[ $DRY_RUN != 1 ]]; then
    local title="Weekly dependency update failed" body="$2"$'\n\n'"Run: ${RUN_URL:-local run}" n
    n="$(gh issue list -R "$OWNER/$1" --state open --search "in:title \"$title\"" \
           --json number -q '.[0].number // empty' 2>/dev/null || true)"
    if [[ -n $n ]]; then
      gh issue comment "$n" -R "$OWNER/$1" --body "$body" || true
    else
      gh issue create -R "$OWNER/$1" --title "$title" --body "$body" || true
    fi
  fi
  exit 1
}

required_checks() {  # $1 repo: names of the checks that must pass, one per line
  {
    gh api "repos/$OWNER/$1/branches/$BASE_BRANCH" \
      --jq '.protection.required_status_checks.contexts[]?' 2>/dev/null || true
    tr ',' '\n' <<< "${REQUIRED_CHECKS-UnitTest}"
  } | sed 's/^ *//; s/ *$//; /^$/d' | sort -u
}

ci_checks() {  # $1 repo, $2 sha: "<name>\t<pass|fail|pending>" for each check run and commit status
  gh api "repos/$OWNER/$1/commits/$2/check-runs?per_page=100" --jq '.check_runs[] | [.name,
      if .status != "completed" then "pending"
      elif .conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral" then "pass"
      else "fail" end] | @tsv' &&
  gh api "repos/$OWNER/$1/commits/$2/status" --jq '.statuses[] | [.context,
      if .state == "pending" then "pending" elif .state == "success" then "pass" else "fail" end] | @tsv'
}

# `gh pr checks --watch` returns as soon as every check reported so far is done,
# which can be before UnitTest or the "code cov" status even shows up. Since the
# merge may bypass branch protection (--admin), wait for the required ones explicitly.
wait_ci() {  # $1 repo, $2 sha: 0 once every check passed, 1 on a failure or timeout
  local required checks last="" r missing deadline=$(( SECONDS + CI_TIMEOUT * 60 ))
  required="$(required_checks "$1")"
  echo "Waiting for the checks on $2, required: ${required//$'\n'/, }"
  while (( SECONDS < deadline )); do
    sleep 30
    checks="$(ci_checks "$1" "$2")" || continue   # API hiccup: try again
    if [[ $checks != "$last" ]]; then printf '%s\n--\n' "$checks"; last=$checks; fi
    if grep -q $'\tfail$' <<< "$checks"; then return 1; fi
    missing=0
    while IFS= read -r r; do
      [[ -z $r ]] || grep -qxF "$r"$'\tpass' <<< "$checks" || missing=1
    done <<< "$required"
    if (( missing == 0 )) && [[ -n $checks ]] && ! grep -q $'\tpending$' <<< "$checks"; then
      return 0
    fi
  done
  echo "Timed out after $CI_TIMEOUT minutes."
  return 1
}

remote_tag_sha() {  # $1 tag: the commit it points to on origin, empty if there is no such tag
  git ls-remote origin "refs/tags/$1" "refs/tags/$1^{}" | tail -1 | cut -f1
}

release() {  # $1 repo, $2 sha: tag the commit <.VERSION>.<number of commits>, like SetTag does
  local repo=$1 sha=$2 version tag run_id n
  version="$(git show "$sha:.VERSION" | tr -d '[:space:]')" || fail "$repo" "No .VERSION file."
  tag="$version.$(git rev-list --count "$sha")"
  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$repo" "Unexpected tag \`$tag\` from .VERSION \`$version\`."
  if [[ $DRY_RUN == 1 ]]; then
    echo "$repo would be tagged $tag"
    TAG="$tag (dry run)"
    return
  fi
  if [[ -z "$(remote_tag_sha "$tag")" ]]; then
    git tag "$tag" "$sha"
    git push -q origin "refs/tags/$tag" || true   # the repo's own Build may have just made it: checked below
  fi
  [[ "$(remote_tag_sha "$tag")" == "$sha" ]] \
    || fail "$repo" "Could not create tag $tag on $sha (it may exist on another commit)."
  NEWTAG[$(go list -m)]="$tag"
  TAG="$tag"
  echo "$repo tagged $tag"

  # Optional: also wait for whatever the tag triggers (the Build workflow runs on v* tags).
  if [[ ${WAIT_TAG_CI:-0} == 1 ]]; then
    run_id=""
    for n in {1..8}; do
      sleep 15
      run_id="$(gh run list -R "$OWNER/$repo" --branch "$tag" --limit 1 \
                  --json databaseId -q '.[0].databaseId // empty')"
      [[ -z $run_id ]] || break
    done
    if [[ -n $run_id ]]; then
      gh run watch "$run_id" -R "$OWNER/$repo" --exit-status --interval 30 >/dev/null \
        || fail "$repo" "Tag $tag was pushed but its workflow failed."
    fi
  fi
}

train_repo() {  # $1 repo
  local repo=$1 dir="$WORK/$1" dep n check_var check checks body others pr sha merge_sha
  gh repo clone "$OWNER/$repo" "$dir" -- --quiet || fail "$repo" "Could not clone $OWNER/$repo."
  cd "$dir"

  if [[ $DRY_RUN != 1 ]]; then
    pr="$(gh pr list -R "$OWNER/$repo" --state open --json number,headRefName \
            -q "[.[] | select(.headRefName | startswith(\"$BRANCH_PREFIX\"))][0].number // empty")"
    [[ -z $pr ]] || fail "$repo" "Dependency PR #$pr from an earlier train is still open; merge or close it first."
  fi
  git switch -q -c "$BRANCH"

  # 1. Upgrade everything (direct, indirect, test deps) within current major versions.
  go get -u -t ./... || fail "$repo" "\`go get -u -t ./...\` failed."

  # 2. Pin our own modules to the exact tags made earlier in this run.
  #    proxy.golang.org's @latest can lag behind a fresh tag, so ask for it explicitly.
  for dep in $(go mod edit -json | jq -r '.Require[]?.Path'); do
    [[ -n "${NEWTAG[$dep]:-}" ]] || continue
    n=0
    until go get "$dep@${NEWTAG[$dep]}"; do
      (( ++n < 6 )) || fail "$repo" "Could not fetch $dep@${NEWTAG[$dep]} from the module proxy."
      sleep 30
    done
  done
  go mod tidy || fail "$repo" "\`go mod tidy\` failed."

  if git diff --quiet -- go.mod go.sum; then
    sha="$(git rev-parse HEAD)"
    if [[ ${RELEASE_UNTAGGED:-0} != 1 || -n "$(git tag --points-at "$sha" --list 'v*')" ]]; then
      echo "$repo is already up to date; no new tag."
      RESULTS+=("$repo: already up to date")
      return
    fi
    # Nothing to upgrade, but $BASE_BRANCH has commits since its last tag:
    # release them, so the downstream repos pick them up.
    checks="$(ci_checks "$repo" "$sha")" || checks=""
    if ! grep -qxF $'UnitTest\tpass' <<< "$checks" || grep -qE $'\t(fail|pending)$' <<< "$checks"; then
      echo "::warning::$repo: $BASE_BRANCH has untagged commits, but CI has not passed on $sha; not releasing it."
      RESULTS+=("$repo: up to date; untagged $BASE_BRANCH not released, its CI has not passed")
      return
    fi
    release "$repo" "$sha"
    RESULTS+=("$repo: up to date; released untagged $BASE_BRANCH as $TAG")
    return
  fi

  # 3. The repo's own build and tests, before spending CI time.
  check_var="CHECK_${repo//[^a-zA-Z0-9_]/_}"
  check="${!check_var-$CHECK}"
  if [[ -n $check ]]; then
    echo "Running: $check"
    bash -c "$check" || fail "$repo" "\`$check\` failed locally after the upgrade."
    compose_down "$dir"
  fi

  # The check may regenerate or reformat tracked files (go generate, gofmt). Keep
  # them: CI runs the same targets, and xpki fails when they leave the tree dirty.
  git add -u
  git commit -q -m "$TITLE"

  if [[ $DRY_RUN == 1 ]]; then
    git --no-pager show --stat --format='%n%s' HEAD
    git --no-pager diff HEAD~1 -U0 -- go.mod
    RESULTS+=("$repo: dry run, would open a PR")
    return
  fi

  # 4. PR + wait for CI.
  body="Weekly dependency update by the release train. Run: ${RUN_URL:-local run}"$'\n\n```diff\n'
  body+="$(git diff HEAD~1 -U0 -- go.mod | grep -E '^[-+][^-+]' || true)"$'\n```'
  others="$(git diff --name-only HEAD~1 -- . ':!go.mod' ':!go.sum' | sed 's/^/- /')"
  if [[ -n $others ]]; then body+=$'\n\n'"Also changed by \`$check\`:"$'\n'"$others"; fi

  git push -q --force -u origin "$BRANCH"
  sha="$(git rev-parse HEAD)"
  pr="$(gh pr create -R "$OWNER/$repo" --base "$BASE_BRANCH" --head "$BRANCH" --title "$TITLE" --body "$body")"
  echo "Opened $pr"
  wait_ci "$repo" "$sha" || fail "$repo" "CI failed on the dependency PR $pr (left open for review)."

  # 5. Merge, then tag the merge commit.
  local merge_flags=(--squash --delete-branch --match-head-commit "$sha")
  if [[ ${MERGE_ADMIN:-0} == 1 ]]; then merge_flags+=(--admin); fi
  gh pr merge "$pr" -R "$OWNER/$repo" "${merge_flags[@]}" || fail "$repo" "Could not merge $pr."
  merge_sha="$(gh pr view "$pr" -R "$OWNER/$repo" --json mergeCommit -q .mergeCommit.oid)"
  git fetch -q origin "$BASE_BRANCH"
  release "$repo" "$merge_sha"
  RESULTS+=("$repo: $TAG, $pr")
}

if [[ -n ${START_FROM:-} && " ${REPOS[*]} " != *" $START_FROM "* ]]; then
  echo "START_FROM=$START_FROM is not one of: ${REPOS[*]}" >&2
  exit 2
fi
skip="${START_FROM:+1}"
for repo in "${REPOS[@]}"; do
  if [[ $repo == "${START_FROM:-}" ]]; then skip=""; fi
  if [[ -n $skip ]]; then
    RESULTS+=("$repo: skipped, START_FROM=$START_FROM")
    continue
  fi
  echo "::group::$repo"
  train_repo "$repo"
  echo "::endgroup::"
done

echo "Train finished. New tags:"
for m in "${!NEWTAG[@]}"; do echo "  $m ${NEWTAG[$m]}"; done
