#!/usr/bin/env bash
# Weekly dependency "release train" for interdependent Go modules.
#
# For each repo, in dependency order (upstream first):
#   1. go get -u, then pin our own modules to the tags created earlier in this run
#      (go mod tidy runs after step 2, once the check has generated any code)
#   2. run the repo's own check (default `make all`: installs the tools and starts
#      the docker / softhsm environment the tests need, then runs covtest)
#   3. open a PR, wait for CI including the required checks, and for an approval unless
#      MERGE_ADMIN=1; stop the whole train (and notify, see notify.sh) if that fails
#   4. squash-merge and tag the merge commit the way the repos' SetTag workflow does:
#      $(cat .VERSION).$(git rev-list --count HEAD), e.g. v1.0.312
# A PR left open by a run that stopped is picked up again by the next run.
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
#   IGNORE_CHECKS    comma-separated checks whose result does not count, even when branch
#                    protection requires them; shell patterns, e.g. "code cov,security/snyk*"
#                    (default: code cov: an upgrade does not change our coverage, and xdb
#                    sits on its 80% line). Only --admin can merge past a required one.
#   CI_TIMEOUT       minutes to wait for the PR checks (default: 90)
#   MERGE_ADMIN      1 = merge with --admin, which skips the required review
#   APPROVERS        without MERGE_ADMIN=1: comma-separated GitHub users asked to review
#                    each PR (not the token's user: a PR author cannot approve it)
#   APPROVAL_TIMEOUT minutes to wait for that approval (default: 120)
#   START_FROM       skip the repos before this one, to resume a train that stopped
#   DRY_RUN          1 = upgrade and run CHECK locally only: no push, PR, tag or issue
#   RELEASE_UNTAGGED 1 = tag a repo with nothing to upgrade when its branch has untagged
#                    commits and green CI, so downstream repos get them
#   KEEP_WORK        1 = keep the clones after a successful run (always kept on failure)
#   WAIT_TAG_CI      1 = also wait for the workflow triggered by the new tag
#   RUN_URL          link to this run, put in PRs, issues and notifications
#   notification channels: see notify.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/notify.sh"

OWNER="${OWNER:-effective-security}"
read -r -a REPOS <<< "${REPOS:-xlog x xdb metrics xpki porto gogentic protoc-gen-go}"
BASE_BRANCH="${BASE_BRANCH:-main}"
CHECK="${CHECK-make all}"
CI_TIMEOUT="${CI_TIMEOUT:-90}"
IGNORE_CHECKS="${IGNORE_CHECKS-code cov}"
APPROVAL_TIMEOUT="${APPROVAL_TIMEOUT:-120}"
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

fail() {  # $1 repo, $2 message: report it (repo issue + notification) and stop the train
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
    notify "Dependency train stopped at $1" "$body"
    echo "TRAIN_NOTIFIED=1" >> "${GITHUB_ENV:-/dev/null}"   # the workflow's catch-all skips it
  fi
  exit 1
}

required_checks() {  # $1 repo: names of the checks that must pass, one per line
  {
    gh api "repos/$OWNER/$1/branches/$BASE_BRANCH" \
      --jq '.protection.required_status_checks.contexts[]?' 2>/dev/null || true
    tr ',' '\n' <<< "${REQUIRED_CHECKS-UnitTest}"
  } | sed 's/^ *//; s/ *$//; /^$/d' | sort -u | drop_ignored
}

drop_ignored() {  # stdin: check names or "<name>\t<state>" lines; prints those IGNORE_CHECKS does not match
  local line p keep pats=()
  while IFS= read -r p; do [[ -z $p ]] || pats+=("$p"); done \
    < <(tr ',' '\n' <<< "$IGNORE_CHECKS" | sed 's/^ *//; s/ *$//')
  while IFS= read -r line; do
    keep=1
    for p in "${pats[@]}"; do
      # $p unquoted on purpose: a shell pattern such as security/snyk*
      if [[ ${line%%$'\t'*} == $p ]]; then keep=""; fi
    done
    if [[ -n $keep ]]; then printf '%s\n' "$line"; fi
  done
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
  echo "Waiting for the checks on $2, required: ${required//$'\n'/, }; ignored: ${IGNORE_CHECKS:-none}"
  while (( SECONDS < deadline )); do
    sleep 30
    checks="$(ci_checks "$1" "$2")" || continue   # API hiccup: try again
    if [[ $checks != "$last" ]]; then printf '%s\n--\n' "$checks"; last=$checks; fi
    checks="$(drop_ignored <<< "$checks")"
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

# Without --admin the merge has to satisfy branch protection, including the review.
await_approval() {  # $1 repo, $2 pr url: returns once the PR is approved (or already merged)
  local deadline=$(( SECONDS + APPROVAL_TIMEOUT * 60 )) asked="" state users a args
  while :; do
    state="$(gh pr view "$2" -R "$OWNER/$1" --json state,reviewDecision \
               -q '.state + " " + (.reviewDecision // "")' || echo error)"   # error: API hiccup, ask again
    case "$state" in
      MERGED*|"OPEN APPROVED"|"OPEN ") return 0 ;;   # "" = no review required
      CLOSED*) fail "$1" "$2 was closed while waiting for an approval." ;;
      *CHANGES_REQUESTED) fail "$1" "Changes were requested on $2. Push them to its branch, then run the train again with start_from=$1." ;;
    esac
    if [[ -z $asked && $state == "OPEN REVIEW_REQUIRED" ]]; then
      asked=1
      if [[ -n ${APPROVERS:-} ]]; then
        IFS=, read -r -a users <<< "$APPROVERS"
        args=()
        for a in "${users[@]}"; do args+=(-f "reviewers[]=${a// /}"); done
        gh api -X POST "repos/$OWNER/$1/pulls/${2##*/}/requested_reviewers" "${args[@]}" >/dev/null || true
      fi
      notify "Dependency train: $1 needs an approval" "$2 passed CI and needs an approving review before the train merges and tags it. The train waits up to $APPROVAL_TIMEOUT minutes; after that, approve it and run the train again with start_from=$1."$'\n\n'"Run: ${RUN_URL:-local run}"
      echo "Waiting up to $APPROVAL_TIMEOUT minutes for an approval on $2"
    fi
    (( SECONDS < deadline )) \
      || fail "$1" "$2 was not approved within $APPROVAL_TIMEOUT minutes (left open). Approve it, then run the train again with start_from=$1."
    sleep 60
  done
}

land() {  # $1 repo, $2 pr url: wait for CI (and the approval), merge, tag the merge commit
  local repo=$1 pr=$2 sha merge_sha flags=(--squash --delete-branch)
  sha="$(gh pr view "$pr" -R "$OWNER/$repo" --json headRefOid -q .headRefOid)"
  wait_ci "$repo" "$sha" \
    || fail "$repo" "CI failed on the dependency PR $pr (left open). Push a fix to its branch, then run the train again with start_from=$repo."
  if [[ ${MERGE_ADMIN:-0} == 1 ]]; then flags+=(--admin); else await_approval "$repo" "$pr"; fi
  # The approver may have merged it already.
  if [[ "$(gh pr view "$pr" -R "$OWNER/$repo" --json state -q .state)" != MERGED ]]; then
    gh pr merge "$pr" -R "$OWNER/$repo" "${flags[@]}" --match-head-commit "$sha" \
      || fail "$repo" "Could not merge $pr."
  fi
  merge_sha="$(gh pr view "$pr" -R "$OWNER/$repo" --json mergeCommit -q .mergeCommit.oid)"
  git fetch -q origin "$BASE_BRANCH"
  release "$repo" "$merge_sha"
  RESULTS+=("$repo: $TAG, $pr")
}

train_repo() {  # $1 repo
  local repo=$1 dir="$WORK/$1" dep n check_var check checks body others pr sha
  gh repo clone "$OWNER/$repo" "$dir" -- --quiet || fail "$repo" "Could not clone $OWNER/$repo."
  cd "$dir"

  # A PR left open by an earlier run (its CI failed, or it waited for an approval):
  # carry on with it rather than open another one. Close it to start over instead.
  pr="$(gh pr list -R "$OWNER/$repo" --state open --json url,headRefName \
          -q "[.[] | select(.headRefName | startswith(\"$BRANCH_PREFIX\"))][0].url // empty")"
  if [[ -n $pr ]]; then
    if [[ $DRY_RUN == 1 ]]; then
      RESULTS+=("$repo: dry run, would resume $pr")
    else
      echo "Resuming $pr, left open by an earlier run"
      land "$repo" "$pr"
    fi
    return
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
  # No `go mod tidy` yet: it runs after the check, see below.

  if git diff --quiet -- go.mod go.sum; then
    sha="$(git rev-parse HEAD)"
    if [[ -n "$(git tag --points-at "$sha" --list 'v*')" ]] ||
       [[ ${RELEASE_UNTAGGED:-0} != 1 && "$(git log -1 --format=%s "$sha")" != "$TITLE"* ]]; then
      echo "$repo is already up to date; no new tag."
      RESULTS+=("$repo: already up to date")
      return
    fi
    # Nothing to upgrade, but $BASE_BRANCH has commits since its last tag (with
    # RELEASE_UNTAGGED=1, or a train PR someone merged by hand): release them, so
    # the downstream repos pick them up.
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
    # Tidy only now that the check has generated the code that is not committed (protoc-gen-go's
    # e2e *.pb.go): in a fresh clone tidy would drop the modules only that code imports, and the
    # check's `go vet` would then fail with "updates to go.mod needed". Without a check, no tidy.
    go mod tidy || fail "$repo" "\`go mod tidy\` failed after \`$check\`."
  fi
  if git diff --quiet -- go.mod go.sum; then   # tidy took back all that go get changed
    echo "$repo is already up to date after go mod tidy; no new tag."
    RESULTS+=("$repo: already up to date")
    return
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

  git push -q --force -u origin "$BRANCH" \
    || fail "$repo" "Could not push $BRANCH to $OWNER/$repo. Check that DEPS_BOT_TOKEN has Contents: write on it."
  pr="$(gh pr create -R "$OWNER/$repo" --base "$BASE_BRANCH" --head "$BRANCH" --title "$TITLE" --body "$body")" \
    || fail "$repo" "Could not open a PR for $BRANCH in $OWNER/$repo. Check that DEPS_BOT_TOKEN has Pull requests: write on it."
  echo "Opened $pr"

  # 5. Merge once it is green (and approved), then tag the merge commit.
  land "$repo" "$pr"
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
