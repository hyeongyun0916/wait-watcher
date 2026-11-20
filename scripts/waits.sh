#!/usr/bin/env bash
# Waits watcher: things the user is waiting on from other people, stored in the "대기 보드" artifact's
# database (ART_URL) and checked every 10 minutes by a headless Claude run, which records results there
# and returns Slack texts that this script posts to a Slack channel through an incoming webhook.
#
#   waits.sh check [id]        one check tick (all open waits, or one)
#   waits.sh flush             retry queued session messages whose session is running again
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
QUEUE="$DIR/session-queue.json"     # session messages waiting for their session to come back
INTERVAL="${INTERVAL:-600}"
MODEL="${MODEL:-claude-sonnet-5-5}"
WEBHOOK_FILE="$DIR/webhook.url"   # Slack incoming webhook URL (keep it mode 600; it is a secret)
SLACK_MENTION="${SLACK_MENTION:-}"  # e.g. <@U0XXXXXXX> to mention yourself in every post
# The check run needs Bash (gh) without prompts, so it runs in auto mode. A session holds cross-session
# messages from a sender in a more permissive mode than its own, so the "대기가 끝났으니 확인해" message is sent
# from a separate default-mode run that may use only the messaging and database tools (deliver_session_messages).
PERMISSION_MODE="${PERMISSION_MODE:-auto}"
STUCK_AFTER="${STUCK_AFTER:-18}"   # consecutive failures (18 x 10 min = 3 h) before giving up
QUEUE_HOURS="${QUEUE_HOURS:-24}"   # how long a session message waits for its session
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

live_socket() { # $1 = session id -> socket of its newest live process, or nothing
  local f pid
  for f in "$HOME"/.claude/sessions/*.json; do
    jq -e --arg s "$1" '.sessionId == $s and .messagingSocketPath != null' "$f" > /dev/null 2>&1 || continue
    pid="$(jq -r .pid "$f")"; kill -0 "$pid" 2>/dev/null || continue
    jq -r '"\(.startedAt) \(.messagingSocketPath)"' "$f"
  done | sort -n | tail -1 | cut -d' ' -f2-
}

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
- SESSIONS_PY: $CODE/sessions.py

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
  send_session_messages "$results"
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

send_session_messages() { # $1 = results array
  deliver_session_messages "$(echo "$1" | jq -c '[.[] | select(.status == "done" and .session_message.to != null and .session_message.text != null)
                              | {id, to: .session_message.to, session_id: .session_message.session_id, text: .session_message.text}]')"
}

# Sessions come and go (an idle editor session's process exits and a new one starts later), so a message
# whose session is not running waits in $QUEUE and is retried every tick until QUEUE_HOURS pass.
flush_session_queue() {
  [ -s "$QUEUE" ] || return 0
  local cutoff q
  cutoff="$(date -d "-${QUEUE_HOURS} hours" +%s)"
  q="$(jq -c --argjson c "$cutoff" '[.[] | select(.queued_epoch >= $c and (.wake_tries // 0) < 3)]' "$QUEUE")"
  echo "$q" > "$QUEUE"
  [ "$(echo "$q" | jq length)" -gt 0 ] || return 0
  echo "$(now) session queue: retrying $(echo "$q" | jq -c 'map(.id)')" >> "$LOG"
  deliver_session_messages "$(echo "$q" | jq -c 'map({id, to, session_id, text, wake_tries})')"
}

# A wait's session may not be running (an idle editor session's process exits). Resume it headless so it can
# check the result on its own; it gets read-only tools only, and its report lands in its transcript, which the
# user sees on reopening it. Never resume a session a live process holds: two writers would tangle its transcript.
WAKE_ALLOWED=(Read Grep Glob ToolSearch WebSearch ArtifactComments
  "Bash(gh pr view:*)" "Bash(gh pr diff:*)" "Bash(gh pr checks:*)" "Bash(gh run view:*)" "Bash(gh issue view:*)"
  "Bash(git log:*)" "Bash(git show:*)" "Bash(git diff:*)" "Bash(git status:*)"
  mcp__claude_ai_Atlassian_MCP__getJiraIssue mcp__claude_ai_Atlassian_MCP__listJiraIssueComments
  mcp__claude_ai_Atlassian_MCP__searchJiraIssuesUsingJql mcp__claude_ai_Atlassian_MCP__getConfluenceContent
  mcp__claude_ai_Atlassian_MCP__executeRead mcp__claude_ai_Slack__slack_read_thread
  mcp__claude_ai_Slack__slack_read_channel mcp__claude_ai_Claude_Docs__read mcp__claude_ai_Claude_Docs__query
  mcp__claude_ai_Claude_Docs__guide)
WAKE_DENIED=(Edit Write NotebookEdit SendMessage ArtifactData mcp__claude_ai_Slack__slack_send_message
  mcp__claude_ai_Slack__slack_schedule_message mcp__claude_ai_Atlassian_MCP__executeWrite
  mcp__claude_ai_Atlassian_MCP__executeDestructive mcp__claude_ai_Atlassian_MCP__addOrEditJiraIssueComment
  mcp__claude_ai_Claude_Docs__batch mcp__claude_ai_Claude_Docs__update)

wake_session() { # $1 = {id, session_id, text}; exit 0 when the resumed session ran and answered
  local sid cwd transcript out
  sid="$(echo "$1" | jq -r '.session_id // empty')"
  [ -n "$sid" ] || return 1
  sessions_json | jq -e --arg s "$sid" 'map(.session_id) | index($s)' > /dev/null && return 1
  transcript="$(ls -t "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)"
  [ -n "$transcript" ] || return 1
  cwd="$(grep -m1 -o '"cwd":"[^"]*"' "$transcript" | sed 's/^"cwd":"//; s/"$//')"
  [ -d "$cwd" ] || return 1
  out="$(cd "$cwd" && timeout 900 claude -p "$(echo "$1" | jq -r .text)

(이 세션은 꺼져 있어서 대기 확인기가 화면 없이 깨웠습니다. 읽기 전용 도구만 쓸 수 있습니다. 결과를 확인하고 무엇이
바뀌었는지, 다음에 할 일이 무엇인지 정리해 두세요. 승인·댓글·머지·게시처럼 밖에 흔적이 남는 일은 하지 마세요.)" \
      --resume "$sid" --permission-mode default --allowedTools "${WAKE_ALLOWED[@]}" --disallowedTools "${WAKE_DENIED[@]}" \
      --output-format json < /dev/null 2>> "$LOG" | jq -r '.result // empty')" || return 1
  [ -n "$out" ] || return 1
  echo "$(now) woke $sid for $(echo "$1" | jq -r .id): $(echo "$out" | tr '\n' ' ' | cut -c1-300)" >> "$LOG"
}

deliver_session_messages() { # $1 = [{id, to, session_id, text}]
  # Delivery runs in default mode (sessions hold messages from a more permissive sender), but a default-mode -p
  # run cannot write the database, so a second, auto-mode run that may use only ArtifactData records outcomes.
  local msgs="$1" out outcomes
  [ "$(echo "$msgs" | jq length)" -gt 0 ] || return 0
  # Names change and two processes can share one (or hold the same session id), so a live session is addressed
  # by the socket of its newest process, found by session id. Only a session with no id falls back to its name.
  local m2='[]' one sock
  while read -r one; do
    sock="$(live_socket "$(echo "$one" | jq -r '.session_id // empty')")"
    [ -n "$sock" ] && one="$(echo "$one" | jq -c --arg t "uds:$sock" '.to = $t')"
    m2="$(echo "$m2" | jq -c --argjson o "$one" '. + [$o]')"
  done < <(echo "$msgs" | jq -c '.[]')
  msgs="$m2"
  out="$(cd "$DIR" && timeout 300 claude -p "Deliver finished-wait messages to other Claude sessions on this machine.
Load the tools with ToolSearch \"select:SendMessage,ListAgents\". For each entry in MESSAGES: if \"to\" starts with
\"uds:\", SendMessage to exactly that address; otherwise call ListAgents (once) and send to the row whose name equals
\"to\" (none: outcome \"error 세션 없음\"). Send \"text\" verbatim; outcome \"ok\", or \"error <reason>\" if the send failed
(a refused or vanished socket counts as \"error 세션 없음\"). Send nothing else to anyone.
Finish with exactly one line per entry and nothing after: <id> ok   or   <id> error <reason>
MESSAGES:
$msgs" --model "$MODEL" --permission-mode default --allowedTools ToolSearch SendMessage ListAgents \
          --disallowedTools Bash Edit Write NotebookEdit ArtifactData mcp__claude_ai_Slack__slack_send_message \
          --output-format json < /dev/null 2>> "$LOG" | jq -r '.result // empty')" || true
  outcomes="$(echo "$out" | grep -E '^[wt][0-9]+ (ok|error)' | jq -Rnc --arg ts "$(now)" '[inputs | capture("^(?<id>\\S+) (?<ok>ok|error) ?(?<why>.*)$")
      | if .ok == "ok" then {id, fields: {session_notified: $ts, session_notify_error: null}}
        else {id, fields: {session_notify_error: (if .why == "" then "error" else .why end)}} end]')"
  # Anything without a reported outcome counts as undelivered.
  outcomes="$(jq -nc --argjson m "$msgs" --argjson o "${outcomes:-[]}" \
      '$o + [$m[] | .id as $i | select(([$o[].id] | index($i)) == null) | {id: $i, fields: {session_notify_error: "전송 run 결과 없음"}}]')"
  # Wake the sessions that are not running; what cannot be woken waits in the queue.
  local m
  while read -r m; do
    [ -n "$m" ] || continue
    if wake_session "$m"; then
      outcomes="$(echo "$outcomes" | jq -c --arg i "$(echo "$m" | jq -r .id)" --arg ts "$(now)" \
        'map(if .id == $i then {id, fields: {session_notified: $ts, session_notify_via: "wake", session_notify_error: null}} else . end)')"
    else
      msgs="$(echo "$msgs" | jq -c --arg i "$(echo "$m" | jq -r .id)" 'map(if .id == $i then .wake_tries = ((.wake_tries // 0) + 1) else . end)')"
    fi
  done < <(jq -nc --argjson m "$msgs" --argjson o "$outcomes" \
            '($o | map(select(.fields.session_notify_error == "세션 없음") | .id)) as $miss | $m[] | .id as $i | select($miss | index($i))')
  echo "$(now) session messages: $(echo "$outcomes" | jq -c 'map({id} + .fields)')" >> "$LOG"
  # Queue what found no session; drop from the queue what was delivered.
  local q; q="$(cat "$QUEUE" 2>/dev/null || echo '[]')"
  q="$(jq -nc --argjson q "$q" --argjson m "$msgs" --argjson o "$outcomes" --argjson e "$(date +%s)" '
      ($o | map(select(.fields.session_notify_error == "세션 없음") | .id)) as $miss
      | ($o | map(select(.fields.session_notified != null) | .id)) as $sent
      | ($q | map(select(.id as $i | ($sent + $miss) | index($i) | not)))
        + [$m[] | .id as $i | select($miss | index($i)) | . + {queued_epoch: (($q | map(select(.id == $i)) | .[0].queued_epoch) // $e)}]')"
  echo "$q" > "$QUEUE"
  (cd "$DIR" && timeout 300 claude -p "Record outcomes in an artifact database. Load ArtifactData with ToolSearch
\"select:ArtifactData\". For each entry in OUTCOMES: ArtifactData get on $ART_URL, collection waits, doc_id = id; then
ArtifactData update on that doc pinned with that version, passing the entry's \"fields\" object itself as the
update's data (so the document gets top-level fields such as session_notified; never nest them under another key).
On a version conflict, re-read and redo. Write nothing else.
OUTCOMES:
$outcomes" --model "$MODEL" --permission-mode auto --allowedTools ToolSearch ArtifactData \
      --disallowedTools Bash Edit Write NotebookEdit SendMessage mcp__claude_ai_Slack__slack_send_message \
      --output-format json < /dev/null > /dev/null 2>> "$LOG") || echo "$(now) session outcome record failed" >> "$LOG"
}

cmd_loop() {
  while :; do
    cmd_check || echo "$(now) tick error" >> "$LOG"
    flush_session_queue || echo "$(now) session queue error" >> "$LOG"
    sleep "$INTERVAL"
  done
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
  check|loop|start|notify|flush) require_config ;;
esac
case "${1:-}" in
  check) cmd_check "${2:-}" ;;
  flush) flush_session_queue ;;
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
