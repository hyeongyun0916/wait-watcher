#!/usr/bin/env bash
# Waits watcher: things the user is waiting on from other people, stored in the "대기 보드" artifact's
# database (ART_URL) and checked by a headless Claude run, which records results there and returns Slack
# texts that this script posts to a Slack channel through an incoming webhook.
# Every tick (INTERVAL) runs cheap probes in bash and calls Claude only for waits whose probe changed; a full
# Claude check of every open wait runs every FULL_EVERY seconds (and catches waits that have no probe).
#
#   waits.sh check [id,id...]  one Claude check now (all open waits, or those)
#   waits.sh tick              probes, then a Claude check only if something changed or a full check is due
#   waits.sh flush             retry queued session messages whose session is running again
#   waits.sh loop              tick every $INTERVAL seconds forever
#   waits.sh start | stop | status
#   waits.sh doctor            can a headless run load ArtifactData and read the board? (start runs it first)
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
PROBES="$DIR/probes.json"          # per open wait: probes, last fingerprint, recheck time (rebuilt by full checks)
FULLFILE="$DIR/full.at"             # epoch of the last full check that reached the database
INTERVAL="${INTERVAL:-1200}"        # probe tick
FULL_EVERY="${FULL_EVERY:-3600}"    # full Claude check of every open wait
PROBE_FAIL_RETRY="${PROBE_FAIL_RETRY:-3600}"  # a wait whose probe fails is handed to Claude at most this often
FRESH_HOURS="${FRESH_HOURS:-24}"   # a wait without probes registered or reset this recently is checked every tick
MODEL="${MODEL:-claude-haiku-5-5}"
HELPER_MODEL="${HELPER_MODEL:-claude-haiku-5-5}"  # the mechanical delivery and recording runs"
WEBHOOK_FILE="$DIR/webhook.url"   # Slack incoming webhook URL (keep it mode 600; it is a secret)
SLACK_MENTION="${SLACK_MENTION:-}"  # e.g. <@U0XXXXXXX> to mention yourself in every post
# The check run needs Bash (gh) without prompts, so it runs in auto mode. A session holds cross-session
# messages from a sender in a more permissive mode than its own, so the "대기가 끝났으니 확인해" message is sent
# from a separate default-mode run that may use only the messaging and database tools (deliver_session_messages).
PERMISSION_MODE="${PERMISSION_MODE:-auto}"
STUCK_AFTER="${STUCK_AFTER:-18}"   # consecutive failed checks of one wait before the checker marks it stuck
FAIL_ALERT_AFTER="${FAIL_ALERT_AFTER:-2}"  # consecutive runs that miss the database before Slack hears about it
FULLTRY="$DIR/full.try"             # epoch of the last full check attempted, reached the database or not
# A `claude -p` started outside a Claude Code session (setsid loop, cron, a plain shell) gets no ArtifactData
# tool unless the entrypoint is one that carries it, and then every check fails with db_ok false. Pin it.
export CLAUDE_CODE_ENTRYPOINT="${WAITS_ENTRYPOINT:-claude-vscode}"
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
  # Alert early, then again every STUCK_AFTER failures, so a loop that silently stopped working is never missed.
  if [ "$n" -eq "$FAIL_ALERT_AFTER" ] || { [ "$n" -gt "$FAIL_ALERT_AFTER" ] && [ $(( (n - FAIL_ALERT_AFTER) % STUCK_AFTER )) -eq 0 ]; }; then
    notify "[대기 루프 실패] 확인 run이 ${n}회 연속 대기 보드 저장소에 접근하지 못했습니다. 그동안 끝난 대기는 알림이 가지 않습니다: $1 (로그 ~/waits/loop.log, 진단 \`waits.sh doctor\`)" || true
  fi
  return 0
}

# A targeted check that cannot reach the database leaves the changed probe unexamined. Tell the user once per
# change instead of retrying silently: the probe change alone is often the event they wait for (a run ended).
alert_unchecked() { # $1 = id, $2 = probes array, $3 = fingerprint
  local prev
  prev="$(jq -r --arg i "$1" '.[$i].alert_fp // ""' "$PROBES" 2>/dev/null || true)"
  [ "$prev" = "$3" ] && return 0
  notify "[대기 확인 실패] 대기 $1 의 probe가 바뀌었지만 확인 run이 대기 보드에 접근하지 못해 완료 여부를 판단하지 못했습니다. 직접 확인하세요: $(echo "$2" | jq -r 'map(.gh // .file) | join(" · ")')" || true
  (
    flock 9
    jq -c --arg i "$1" --arg fp "$3" 'if .[$i] then .[$i].alert_fp = $fp else . end' "$PROBES" > "$PROBES.tmp" \
      && mv "$PROBES.tmp" "$PROBES"
  ) 9> "$PROBES.lock"
}

cmd_doctor() {
  local out
  out="$(cd "$DIR" && timeout 300 claude -p "Load the ArtifactData tool with ToolSearch (query select:ArtifactData).
Then call ArtifactData action get with url $ART_URL, collection meta, doc_id status.
Reply with exactly OK if the get succeeded, else FAIL: <the exact error, or 'tool not found'>." \
    --model "$HELPER_MODEL" --permission-mode "$PERMISSION_MODE" --output-format json < /dev/null 2>> "$LOG" \
    | jq -r '.result' | tail -1)" || out="FAIL: claude run failed"
  echo "$out"
  [ "$out" = OK ]
}

cmd_check() { # $1 = optional comma-separated ids: check only those (targeted); none = full check
  local only="${1:-}" prompt out block results mode=full rc=0
  [ -z "$only" ] && date +%s > "$FULLTRY"
  [ -n "$only" ] && mode=targeted
  prompt="$(cat "$CODE/../references/check-prompt.md")

## Run parameters

- ART_URL: $ART_URL
- CHECKED_AT: $(now)
- STUCK_AFTER: $STUCK_AFTER
- MODE: $mode
- ONLY_IDS: ${only:-(none: every open wait)}
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
          --output-format json < /dev/null 2>> "$LOG")" || { run_failed "claude run failed (exit $?)"; return 1; }
  block="$(echo "$out" | jq -r '.result' | sed -n '/<<<RESULTS/,/RESULTS>>>/p' | sed '1d;$d')"
  if ! echo "$block" | jq -e 'type == "object" and (.results | type == "array")' > /dev/null 2>&1; then
    run_failed "unparseable result: $(echo "$out" | jq -r '.result' | tail -c 300 | tr '\n' ' ')"; return 1
  fi
  results="$(echo "$block" | jq -c '.results')"
  notify_all "$results"
  send_session_messages "$results"
  if [ "$(echo "$block" | jq -r '.db_ok')" = true ]; then
    echo 0 > "$FAILFILE"
    update_probes "$mode" "$only" "$results"
    [ "$mode" = full ] && { date +%s > "$FULLFILE"; sync_sessions; }
  else run_failed "database read/write failed: $(echo "$out" | jq -r '.result' | sed '/<<<RESULTS/,$d' | tail -c 300 | tr '\n' ' ')"; rc=1; fi
  echo "$(now) checked${only:+ $only}: $(echo "$results" | jq -c 'map({id, status})')" >> "$LOG"
  return "$rc"
}

# A probe is structured, never a shell command: the check run writes it from database content, which page
# viewers can edit. {"gh": "repos/...", "jq": "..."} is a read-only `gh api` GET; {"file": "/abs/path"} is a
# stat (size and mtime, or absent). Prints the fingerprint; exits 1 if any probe could not be read.
probe_fp() { # $1 = probes array
  local p path f out fp="" rc=0
  while read -r p; do
    path="$(echo "$p" | jq -r '.gh // empty')"; f="$(echo "$p" | jq -r '.file // empty')"
    if [ -n "$path" ]; then
      [[ "$path" =~ ^repos/[A-Za-z0-9._/-]+(\?[A-Za-z0-9_=\&.-]+)?$ ]] || { rc=1; continue; }
      out="$(timeout 30 gh api "$path" --jq "$(echo "$p" | jq -r '.jq // "."')" 2>/dev/null)" || { rc=1; continue; }
    elif [ -n "$f" ]; then
      [[ "$f" == /* ]] || { rc=1; continue; }
      out="$(stat -c '%s %Y' -- "$f" 2>/dev/null || echo absent)"
    else rc=1; continue; fi
    fp+="$(printf '%s' "$out" | sha1sum | cut -c1-12);"
  done < <(echo "$1" | jq -c '.[]')
  echo "$fp"; return "$rc"
}

# Keep $PROBES equal to the open waits Claude last saw. A full check replaces it; a targeted check replaces the
# entries it was asked about (an id it did not return is no longer open). Done and stuck waits leave it.
update_probes() { # $1 = full|targeted, $2 = ids, $3 = results
  local e r id probes fp ra fu entries='{}' prev
  prev="$(cat "$PROBES" 2>/dev/null || echo '{}')"
  while read -r r; do
    # A result that leaves out probes keeps the ones the wait already had.
    id="$(echo "$r" | jq -r .id)"
    probes="$(echo "$r" | jq -c --argjson prev "$prev" '.probes // $prev[.id].probes // []')"
    fp=""; [ "$(echo "$probes" | jq length)" -gt 0 ] && fp="$(probe_fp "$probes" || true)"
    ra="$(echo "$r" | jq -r '.recheck_at // empty')"; [ -n "$ra" ] && ra="$(date -d "$ra" +%s 2>/dev/null || true)"
    fu="$(echo "$r" | jq -r '.active_since // empty' | cut -c1-25)"
    [ -n "$fu" ] && fu="$(( $(date -d "$fu" +%s 2>/dev/null || echo 0) + FRESH_HOURS * 3600 ))"
    entries="$(echo "$entries" | jq -c --arg i "$id" --argjson p "$probes" --arg fp "$fp" --arg ra "${ra:-0}" \
      --arg fu "${fu:-0}" --argjson t "$(date +%s)" \
      '.[$i] = {probes: $p, fp: $fp, recheck_at: ($ra | tonumber), fresh_until: ($fu | tonumber), llm_at: $t}')"
  done < <(echo "$3" | jq -c '.[] | select(.status == "pending" or .status == "error")')
  (
    flock 9
    e="$(cat "$PROBES" 2>/dev/null || echo '{}')"
    if [ "$1" = full ]; then e="$entries"
    else e="$(echo "$e" | jq -c --arg ids "$2" --argjson n "$entries" 'with_entries(select(.key as $k | $ids | split(",") | index($k) | not)) + $n')"; fi
    echo "$e" > "$PROBES.tmp" && mv "$PROBES.tmp" "$PROBES"
  ) 9> "$PROBES.lock"
}

cmd_tick() {
  local t last try id e ra probes fp due=() n=0
  declare -A changed=()
  t="$(date +%s)"; last="$(cat "$FULLFILE" 2>/dev/null || echo 0)"; try="$(cat "$FULLTRY" 2>/dev/null || echo 0)"
  # A full check is due when the last one that reached the database is stale. When it fails, it is retried
  # at most every FULL_EVERY and this tick still runs the probes below: a failing full check must not starve
  # them, or a wait whose run already ended is never looked at again.
  if [ ! -s "$PROBES" ] || { [ $(( t - last )) -ge "$FULL_EVERY" ] && [ $(( t - try )) -ge "$FULL_EVERY" ]; }; then
    cmd_check && return 0
    [ -s "$PROBES" ] || return 1
  fi
  while read -r id; do
    n=$(( n + 1 )); e="$(jq -c --arg i "$id" '.[$i]' "$PROBES")"
    ra="$(echo "$e" | jq -r '.recheck_at // 0')"
    if [ "$ra" -gt 0 ] && [ "$t" -ge "$ra" ]; then due+=("$id"); continue; fi
    probes="$(echo "$e" | jq -c '.probes // []')"
    if [ "$(echo "$probes" | jq length)" -eq 0 ]; then
      # No probe: a fresh wait is checked every tick, an older one only by the hourly full check.
      [ "$t" -lt "$(echo "$e" | jq -r '.fresh_until // 0')" ] && due+=("$id")
      continue
    fi
    if fp="$(probe_fp "$probes")"; then
      [ "$fp" = "$(echo "$e" | jq -r '.fp // ""')" ] || { due+=("$id"); changed[$id]="$fp"; }
    elif [ $(( t - $(echo "$e" | jq -r '.llm_at // 0') )) -ge "$PROBE_FAIL_RETRY" ]; then due+=("$id"); fi
  done < <(jq -r 'keys[]' "$PROBES")
  if [ ${#due[@]} -eq 0 ]; then echo "$(now) probes: no change ($n watched, full check in $(( (last + FULL_EVERY - t) / 60 )) min)" >> "$LOG"; return 0; fi
  echo "$(now) probes: changed ${due[*]}" >> "$LOG"
  cmd_check "$(IFS=,; echo "${due[*]}")" && return 0
  for id in "${!changed[@]}"; do
    alert_unchecked "$id" "$(jq -c --arg i "$id" '.[$i].probes // []' "$PROBES")" "${changed[$id]}"
  done
  return 1
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

# A wait's session may not be running (an idle editor session's process exits). Resume it headless in auto mode
# so it can act on the result itself; its report lands in its transcript, which the user sees on reopening it.
# Never resume a session a live process holds: two writers would tangle its transcript.
wake_session() { # $1 = {id, session_id, text}; exit 0 when the resumed session ran and answered
  local sid cwd transcript out
  sid="$(echo "$1" | jq -r '.session_id // empty')"
  [ -n "$sid" ] || return 1
  sessions_json | jq -e --arg s "$sid" 'map(.session_id) | index($s)' > /dev/null && return 1
  transcript="$(ls -t "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)"
  [ -n "$transcript" ] || return 1
  cwd="$(grep -m1 -o '"cwd":"[^"]*"' "$transcript" | sed 's/^"cwd":"//; s/"$//')"
  [ -d "$cwd" ] || return 1
  out="$(cd "$cwd" && timeout 1800 claude -p "$(echo "$1" | jq -r .text)

(이 세션은 꺼져 있어서 대기 확인기가 화면 없이 auto 모드로 깨웠습니다. 결과를 확인하고 이 세션에서 하던 일의 다음
단계를 진행하세요. 평소 규칙(CLAUDE.md, 메모리)은 그대로 따릅니다. 끝나면 무엇이 바뀌었고 무엇을 했는지, 남은 일이
무엇인지 정리해 두세요.)" \
      --resume "$sid" --permission-mode auto \
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
  # A session with an id but no live process goes straight to waking: sending to its old name would reach
  # nobody, or the delivery run itself, which the harness may name after the session it is asked to message.
  local m2='[]' send='[]' one sock sid
  while read -r one; do
    sid="$(echo "$one" | jq -r '.session_id // empty')"
    sock="$(live_socket "$sid")"
    [ -n "$sock" ] && one="$(echo "$one" | jq -c --arg t "uds:$sock" '.to = $t')"
    m2="$(echo "$m2" | jq -c --argjson o "$one" '. + [$o]')"
    [ -n "$sock" ] || [ -z "$sid" ] && send="$(echo "$send" | jq -c --argjson o "$one" '. + [$o]')"
  done < <(echo "$msgs" | jq -c '.[]')
  msgs="$m2"
  out=""
  [ "$(echo "$send" | jq length)" -gt 0 ] && out="$(cd "$DIR" && timeout 300 claude -p "Deliver finished-wait messages to other Claude sessions on this machine.
Load the tools with ToolSearch \"select:SendMessage,ListAgents\". For each entry in MESSAGES: if \"to\" starts with
\"uds:\", SendMessage to exactly that address; otherwise call ListAgents (once) and send to the row whose name equals
\"to\" (none: outcome \"error 세션 없음\"). Send \"text\" verbatim; outcome \"ok\", or \"error <reason>\" if the send failed
(a refused or vanished socket counts as \"error 세션 없음\"). Send nothing else to anyone.
Finish with exactly one line per entry and nothing after: <id> ok   or   <id> error <reason>
where <id> is the entry's \"id\" field (w… or t…), never its \"to\".
MESSAGES:
$send" --model "$HELPER_MODEL" --permission-mode default --allowedTools ToolSearch SendMessage ListAgents \
          --disallowedTools Bash Edit Write NotebookEdit ArtifactData mcp__claude_ai_Slack__slack_send_message \
          --output-format json < /dev/null 2>> "$LOG" | jq -r '.result // empty')" || true
  outcomes="$(echo "$out" | grep -E '^[wt][0-9]+ (ok|error)' | jq -Rnc --arg ts "$(now)" '[inputs | capture("^(?<id>\\S+) (?<ok>ok|error) ?(?<why>.*)$")
      | if .ok == "ok" then {id, fields: {session_notified: $ts, session_notify_error: null}}
        else {id, fields: {session_notify_error: (if .why == "" then "error" else .why end)}} end]')"
  # A session not running is missing; anything else without a reported outcome counts as undelivered.
  outcomes="$(jq -nc --argjson m "$msgs" --argjson s "$send" --argjson o "${outcomes:-[]}" \
      '$o + [$m[] | .id as $i | select(([$o[].id] | index($i)) == null)
             | {id: $i, fields: {session_notify_error: (if ([$s[].id] | index($i)) == null then "세션 없음" else "전송 run 결과 없음" end)}}]')"
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
  record_fields "$outcomes" "session outcome"
}

# Write [{id, fields}] onto waits documents through a run that may use only ArtifactData.
record_fields() { # $1 = [{id, fields}], $2 = label for the log
  (cd "$DIR" && timeout 300 claude -p "Record outcomes in an artifact database. Load ArtifactData with ToolSearch
\"select:ArtifactData\". For each entry in OUTCOMES: ArtifactData get on $ART_URL, collection waits, doc_id = id; then
ArtifactData update on that doc pinned with that version, passing the entry's \"fields\" object itself as the
update's data (so the document gets top-level fields such as session_notified; never nest them under another key).
On a version conflict, re-read and redo. Write nothing else.
OUTCOMES:
$1" --model "$HELPER_MODEL" --permission-mode auto --allowedTools ToolSearch ArtifactData \
      --disallowedTools Bash Edit Write NotebookEdit SendMessage mcp__claude_ai_Slack__slack_send_message \
      --output-format json < /dev/null > /dev/null 2>> "$LOG") || echo "$(now) $2 record failed" >> "$LOG"
}

# Keep session, session_title and session_cwd on every document equal to what the session records now. Done in
# code, not by the check run: a model asked to compare dozens of documents skips some.
sync_sessions() {
  local snap="$DIR/snap" fixes
  rm -rf "$snap"
  (cd "$DIR" && timeout 300 claude -p "Load ArtifactData with ToolSearch \"select:ArtifactData\". Call ArtifactData
action=list url=$ART_URL collection=waits query={\"limit\":1000} out_dir=$snap once. Do nothing else." \
      --model "$HELPER_MODEL" --permission-mode auto --allowedTools ToolSearch ArtifactData \
      --disallowedTools Bash Edit Write NotebookEdit SendMessage mcp__claude_ai_Slack__slack_send_message \
      --output-format json < /dev/null > /dev/null 2>> "$LOG") || { echo "$(now) session sync: list failed" >> "$LOG"; return 0; }
  fixes="$(/usr/bin/python3 -I "$CODE/sessions.py" --diff "$snap/waits")" || { echo "$(now) session sync: diff failed" >> "$LOG"; return 0; }
  [ "$(echo "$fixes" | jq length)" -eq 0 ] && return 0
  echo "$(now) session sync: $(echo "$fixes" | jq -c 'map({id} + .fields)')" >> "$LOG"
  record_fields "$fixes" "session sync"
}

cmd_loop() {
  while :; do
    cmd_tick || echo "$(now) tick error" >> "$LOG"
    flush_session_queue || echo "$(now) session queue error" >> "$LOG"
    sleep "$INTERVAL"
  done
}

cmd_start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running (pid $(cat "$PIDFILE"))"; return 0; fi
  # A loop that cannot reach the board looks alive and reports nothing; refuse to start one.
  cmd_doctor || { echo "not started: a headless run cannot read the board (see above)" >&2; return 1; }
  setsid nohup "$CODE/waits.sh" loop >> "$LOG" 2>&1 < /dev/null &
  echo $! > "$PIDFILE"; echo "started (pid $!)"
}

cmd_stop() { [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; echo stopped; }

cmd_status() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "running (pid $(cat "$PIDFILE"))"; else echo "not running"; fi
  echo "board: $ART_URL"
  echo "consecutive database failures: $(cat "$FAILFILE" 2>/dev/null || echo 0)"
  tail -3 "$LOG" 2>/dev/null || true
}

case "${1:-}" in
  check|tick|sync|loop|start|notify|flush|doctor) require_config ;;
esac
case "${1:-}" in
  check) cmd_check "${2:-}" ;;
  sync) sync_sessions ;;
  tick) cmd_tick ;;
  flush) flush_session_queue ;;
  loop) cmd_loop ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  doctor) cmd_doctor ;;
  notify) notify "$2" ;;
  title) /usr/bin/python3 -I "$CODE/sessions.py" "$2" | jq -r '.title // .name' ;;
  add|list|close|todo|refresh)
    echo "waits now live in the board's database ($ART_URL): use ArtifactData (collection waits), then 'waits.sh check <id>'" >&2; exit 1 ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
