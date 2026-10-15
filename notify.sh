#!/usr/bin/env bash
# Sends a message to every configured channel; a channel whose settings are empty is skipped.
# deps-train.sh sources it; to test the settings, run it: ./notify.sh "subject" "body"
#
# Email, through any SMTP server (Gmail or Workspace app password, Amazon SES, SendGrid...):
#   NOTIFY_EMAIL        comma-separated recipients
#   SMTP_URL            smtps://smtp.gmail.com:465, smtp://email-smtp.us-west-2.amazonaws.com:587, ...
#   SMTP_USER           login
#   SMTP_PASSWORD
#   SMTP_FROM           sender address; defaults to SMTP_USER when that is an address (Gmail),
#                       but SES (AKIA...) and SendGrid (apikey) logins are not, so set it there
# Telegram: create a bot with @BotFather, send it a message, then find the chat id in
# https://api.telegram.org/bot<token>/getUpdates
#   TELEGRAM_BOT_TOKEN
#   TELEGRAM_CHAT_ID
#
# A channel that fails only prints a warning: a notification problem never stops the train.

notify_email() {  # $1 subject, $2 body
  local from="${SMTP_FROM:-}" to r rcpt=() auth=()
  if [[ -z $from && ${SMTP_USER:-} == *@* ]]; then from=$SMTP_USER; fi
  if [[ -z $from ]]; then
    echo "::warning::Set SMTP_FROM: SMTP_USER is not an email address, so it cannot be the sender."
    return 1
  fi
  IFS=, read -r -a to <<< "$NOTIFY_EMAIL"
  for r in "${to[@]}"; do rcpt+=(--mail-rcpt "${r// /}"); done
  if [[ -n ${SMTP_USER:-} ]]; then auth=(--user "$SMTP_USER:${SMTP_PASSWORD:-}"); fi
  # LF line ends here; --crlf turns them into the CRLF that SMTP requires.
  printf 'From: %s\nTo: %s\nSubject: %s\nDate: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
      "$from" "$NOTIFY_EMAIL" "$1" "$(date -R)" "$2" |
    curl -fsS --ssl-reqd --crlf --url "$SMTP_URL" "${auth[@]}" \
      --mail-from "$from" "${rcpt[@]}" --upload-file -
}

notify_telegram() {  # $1 subject, $2 body
  curl -fsS -o /dev/null "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$1"$'\n\n'"$2"
}

notify() {  # $1 subject, $2 body
  local sent=""
  if [[ -n ${NOTIFY_EMAIL:-} && -n ${SMTP_URL:-} ]]; then
    sent=1
    notify_email "$1" "$2" || echo "::warning::Could not send the email notification."
  fi
  if [[ -n ${TELEGRAM_BOT_TOKEN:-} && -n ${TELEGRAM_CHAT_ID:-} ]]; then
    sent=1
    notify_telegram "$1" "$2" || echo "::warning::Could not send the Telegram notification."
  fi
  [[ -n $sent ]] || echo "No notification channel is configured; not sent: $1" >&2
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -euo pipefail
  notify "${1:?usage: $0 subject [body]}" "${2:-}"
fi
