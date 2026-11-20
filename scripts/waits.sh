#!/usr/bin/env bash
# Waits watcher: things the user is waiting on from other people, stored in the "대기 보드" artifact's
# database (ART_URL) and checked every 10 minutes by a headless Claude run, which records results there
# and returns Slack texts that this script posts to a Slack channel through an incoming webhook.
#
#   waits.sh check [id]        one check tick (all open waits, or one)
#   waits.sh loop              check every $INTERVAL seconds forever
#   waits.sh start | stop | status
#   waits.sh notify '<text>'   post a Slack text by hand
#   waits.sh title <session>   current UI title of a Claude session
#
# Waits and to-dos are added, closed and edited in the artifact database itself (ArtifactData from a
# Claude session, or the board page); there is no local copy. waits.json.pre-db is the pre-migration backup.
set -euo pipefail

# jq here is a mise shim with no global version, so it fails outside a mise-configured
# directory ("No version is set for shim: jq"). Pin the installed jq explicitly.
JQ_DIR="${JQ_DIR:-$HOME/.local/share/mise/installs/jq/1.7.1}"
[ -x "$JQ_DIR/jq" ] && export PATH="$JQ_DIR:$PATH"

CODE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"   # the skill's scripts/
DIR="${WAITS_HOME:-$HOME/waits}"                          # state: log, pid, webhook, fail count, config
mkdir -p "$DIR"
LOG="$DIR/loop.log"
PIDFILE="$DIR/loop.pid"
FAILFILE="$DIR/fail.count"         # consecutive runs that could not reach the database
INTERVAL="${INTERVAL:-600}"
MODEL="${MODEL:-claude-sonnet-5-5}"
WEBHOOK_FILE="$DIR/webhook.url"   # Slack incoming webhook URL (keep it mode 600; it is a secret)
SLACK_MENTION="${SLACK_MENTION:-}"  # e.g. <@U0XXXXXXX> to mention yourself in every post
# auto, not bypassPermissions: sessions hold cross-session messages from a bypassPermissions sender, so the
# "대기가 끝났으니 확인해" message would never arrive.
PERMISSION_MODE="${PERMISSION_MODE:-auto}"
STUCK_AFTER="${STUCK_AFTER:-18}"   # consecutive failures (18 x 10 min = 3 h) before giving up
# Per-user settings live in $DIR/config.env (see config.env.example next to this script).
[ -f "$DIR/config.env" ] && . "$DIR/config.env"
ART_URL="${ART_URL:-}"              # your 대기 보드 artifact (required)
USER_SLACK_ID="${USER_SLACK_ID:-}"  # your Slack member id, so your own replies are not counted (required)
GH_LOGIN="${GH_LOGIN:-}"            # your GitHub login (required)
JIRA_CLOUD_ID="${JIRA_CLOUD_ID:-}"  # Atlassian site cloudId (optional: leave empty if you do not use Jira/Confluence)
DEFAULT_REPO="${DEFAULT_REPO:-}"    # owner/repo assumed when a PR wait gives only a number (optional)

require_config() {
  local missing=() v
  for v in ART_URL USER_SLACK_ID GH_LOGIN; do [ -n "${!v}" ] || missing+=("$v"); done
  [ -f "$WEBHOOK_FILE" ] || missing+=("webhook.url")
  if [ ${#missing[@]} -gt 0 ]; then
    echo "waits.sh: missing ${missing[*]} — fill $DIR/config.env (from $CODE/config.env.example) and $WEBHOOK_FILE" >&2
    exit 2
  fi
}

now() { date -Iseconds; }

sessions_json() { # live sessions as [{session_id, name, title}]
  /usr/bin/python3 -I -c "import json,sys; sys.path.insert(0, sys.argv[1]); import sessions; print(json.dumps(sessions.live_sessions(), ensure_ascii=False))" "$CODE"
}

# The database is only reachable through Claude, so a run that cannot reach it leaves no trace there.
# Count such runs locally and warn once when they span STUCK_AFTER ticks.
run_failed() {
  local n; n=$(( $(cat "$FAILFILE" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAILFILE"
  echo "$(now) $1 (consecutive failures: $n)" >> "$LOG"
  [ "$n" -eq "$STUCK_AFTER" ] && notify "[대기 루프 실패] 확인 run이 ${n}회 연속 대기 보드 저장소에 접근하지 못했습니다: $1 (로그 ~/waits/loop.log)"
  return 0
}

cmd_check() { # $1 = optional id: check only that wait
  local only="${1:-}" prompt out block results
  prompt="$(cat "$CODE/../references/check-prompt.md")

## Run parameters

- ART_URL: $ART_URL
- CHECKED_AT: $(now)
- STUCK_AFTER: $STUCK_AFTER
- ONLY_ID: ${only:-(none: every open wait)}
- JIRA_CLOUD_ID: ${JIRA_CLOUD_ID:-(none: no Atlassian site)}
- USER_SLACK_ID: $USER_SLACK_ID
- GH_LOGIN: $GH_LOGIN
- DEFAULT_REPO: ${DEFAULT_REPO:-(none)}

SESSIONS:
\`\`\`json
$(sessions_json)
\`\`\`"
  out="$(cd "$DIR" && timeout 900 claude -p "$prompt" --model "$MODEL" \
          --permission-mode "$PERMISSION_MODE" --disallowedTools Edit Write NotebookEdit \
            mcp__claude_ai_Slack__slack_send_message mcp__claude_ai_Slack__slack_schedule_message \
            "Bash(gh pr merge:*)" "Bash(gh pr review:*)" "Bash(gh pr comment:*)" "Bash(gh pr edit:*)" \
            "Bash(gh pr close:*)" "Bash(gh pr ready:*)" "Bash(gh issue:*)" "Bash(gh api -X:*)" \
            "Bash(gh api --method:*)" "Bash(gh api -f:*)" "Bash(gh api -F:*)" "Bash(git:*)" "Bash(rm:*)" \
            "Bash(kubectl:*)" "Bash(curl:*)" \
          --output-format json < /dev/null 2>> "$LOG")" || { run_failed "claude run failed (exit $?)"; return 0; }
  block="$(echo "$out" | jq -r '.result' | sed -n '/<<<RESULTS/,/RESULTS>>>/p' | sed '1d;$d')"
  if ! echo "$block" | jq -e 'type == "object" and (.results | type == "array")' > /dev/null 2>&1; then
    run_failed "unparseable result: $(echo "$out" | jq -r '.result' | tail -c 300 | tr '\n' ' ')"; return 0
  fi
  results="$(echo "$block" | jq -c '.results')"
  notify_all "$results"
  if [ "$(echo "$block" | jq -r '.db_ok')" = true ]; then echo 0 > "$FAILFILE"
  else run_failed "database read/write failed"; fi
  echo "$(now) checked${only:+ $only}: $(echo "$results" | jq -c 'map({id, status})')" >> "$LOG"
}

notify() { # $1 = Slack mrkdwn text; posted as the Waits Watcher app so the user gets notified
  local body
  body="$(jq -n --arg t "${SLACK_MENTION:+$SLACK_MENTION }$1" '{text: $t}')"
  curl -sf -m 20 -X POST -H 'Content-type: application/json' --data "$body" "$(cat "$WEBHOOK_FILE")" > /dev/null \
    || echo "$(now) webhook post failed" >> "$LOG"
}

notify_all() { # post every notify text in a results array
  local n
  echo "$1" | jq -c '.[] | select(.notify != null and .notify != "") | .notify' | while read -r n; do
    notify "$(echo "$n" | jq -r .)"
  done
}

cmd_loop() {
  while :; do cmd_check || echo "$(now) tick error" >> "$LOG"; sleep "$INTERVAL"; done
}

cmd_start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running (pid $(cat "$PIDFILE"))"; return 0; fi
  setsid nohup "$CODE/waits.sh" loop >> "$LOG" 2>&1 < /dev/null &
  echo $! > "$PIDFILE"; echo "started (pid $!)"
}

cmd_stop() { [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; echo stopped; }

cmd_status() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "running (pid $(cat "$PIDFILE"))"; else echo "not running"; fi
  echo "board: $ART_URL"
  tail -3 "$LOG" 2>/dev/null || true
}

case "${1:-}" in
  check|loop|start|notify) require_config ;;
esac
case "${1:-}" in
  check) cmd_check "${2:-}" ;;
  loop) cmd_loop ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  notify) notify "$2" ;;
  title) /usr/bin/python3 -I "$CODE/sessions.py" "$2" | jq -r '.title // .name' ;;
  add|list|close|todo|refresh)
    echo "waits now live in the board's database ($ART_URL): use ArtifactData (collection waits), then 'waits.sh check <id>'" >&2; exit 1 ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
