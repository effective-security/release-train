# release-train

Weekly dependency upgrades for Effective Security

Order:

- `github.com/effective-security/xlog`
- `github.com/effective-security/x` -> xlog
- `github.com/effective-security/xdb` -> xlog, x
- `github.com/effective-security/metrics` -> xlog, x
- `github.com/effective-security/xpki` -> xlog, x, metrics
- `github.com/effective-security/porto` -> xlog, x, metrics, xdb, xpki
- `github.com/effective-security/gogentic` -> xlog, x, metrics, xdb, xpki, porto
- `github.com/effective-security/protoc-gen-go` -> xlog, x, porto

## How it works

[`deps-train.sh`](deps-train.sh) runs every Friday from
[`weekly-deps.yml`](.github/workflows/weekly-deps.yml), and handles the repos one at a time in the order above:

1. `go get -u -t ./...`, then pins our own modules to the tags created earlier in the same run
   (the module proxy can lag behind a fresh tag).
2. Runs `make all` in the clone, which installs the tools, starts the environment the tests need
   (localstack and SQL containers for xdb, local KMS and softhsm for xpki) and runs `covtest`.
   The containers are stopped before the next repo.
3. Opens a `deps/weekly-YYYYMMDD` PR and waits for every check, including the required
   `UnitTest` and `code cov`. With `MERGE_ADMIN: "0"` it also waits for an approving review
   (see [Notifications](#notifications)).
4. Squash-merges the PR and tags the merge commit the same way the repos' SetTag workflow does:
   `$(cat .VERSION).$(git rev-list --count HEAD)`, for example `v1.0.312`. A push to `main` only
   tags by itself when `.VERSION` changes, so the train does it.

A repo that is already up to date is skipped and keeps its tag. If any step fails, the train
stops, leaves the PR open, opens (or comments on) a "Weekly dependency update failed" issue in
that repo and sends a notification. Push a fix to the PR's branch (or approve it), then use
**Run workflow** with `start_from` set to that repo: the train picks the open PR up again, merges
and tags it, and goes on. Close the PR instead to drop that week's update. If you merge it by
hand, the next run still tags it.

## Setup

- `DEPS_BOT_TOKEN` secret: a PAT (or GitHub App token) with contents, pull requests and issues
  write on all the repos. It cannot be `GITHUB_TOKEN`, because pushes and PRs made with it do not
  trigger CI. The repos require an approving review, and the bot cannot approve its own PR, so
  the train merges with `--admin` (`MERGE_ADMIN: "1"`), and the token's user must be an admin.
  It only does that after the checks have passed.

## Notifications

[`notify.sh`](notify.sh) sends a message when the train stops (a failure, a timeout) and when a
PR needs an approval. Every channel that has its settings is used; the others are skipped. Set
them under **Settings > Secrets and variables > Actions** of this repo:

| Channel  | Variables                                                 | Secrets                      |
| -------- | --------------------------------------------------------- | ---------------------------- |
| Email    | `NOTIFY_EMAIL` (comma-separated), `SMTP_URL`, `SMTP_FROM` | `SMTP_USER`, `SMTP_PASSWORD` |
| Telegram | `TELEGRAM_CHAT_ID`                                        | `TELEGRAM_BOT_TOKEN`         |

Email goes through any SMTP server, for example `smtps://smtp.gmail.com:465` with a Google
[app password](https://myaccount.google.com/apppasswords), or Amazon SES / SendGrid SMTP
credentials. `SMTP_FROM` is the sender address; it can stay empty when `SMTP_USER` is an address
(Gmail), but SES and SendGrid logins are not, so set it to a verified sender there. For Telegram, create a bot with [@BotFather](https://t.me/BotFather), send it a
message, and read the chat id from `https://api.telegram.org/bot<token>/getUpdates`. To check the
settings, export them and run `./notify.sh "Test" "Hello"`. WhatsApp can be added as another
function in `notify.sh`.

Approvals: with `MERGE_ADMIN: "0"` the train asks the `APPROVERS` variable (comma-separated
GitHub users) to review each PR, notifies, and waits up to `APPROVAL_TIMEOUT` minutes. GitHub also
emails the requested reviewers itself. The PR author cannot approve its own PR, so with
`DEPS_BOT_TOKEN` belonging to you, someone else must approve: use a separate bot account or a
GitHub App token if you want to approve them yourself. Repos that require no review (xpki,
gogentic) are merged without waiting.

## Running locally

```sh
DRY_RUN=1 ./deps-train.sh                      # upgrade + make all for every repo, no push
DRY_RUN=1 CHECK= REPOS="xpki porto" ./deps-train.sh   # only show what would be upgraded
```

`make all` for xpki and xdb uses the same fixed docker compose project names and softhsm slot
as a normal checkout, so a local run replaces those containers and the `xpki_unittest` slot.

Other settings (all env vars, documented at the top of the script): `CHECK_<repo>` to replace
`make all` for one repo, `REQUIRED_CHECKS`, `CI_TIMEOUT`, `WAIT_TAG_CI`, `KEEP_WORK`, and
`RELEASE_UNTAGGED=1` to also tag repos that have nothing to upgrade but have commits on `main`
since their last tag.
