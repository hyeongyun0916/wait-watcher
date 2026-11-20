---
name: waits-watcher
description: Use when the user says they are waiting on someone else and wants to be told when it happens — "PROJ-123 철수 답변 대기", "pr-42 리뷰 대기", "다시 대기", "할 일 추가", "뭐 기다리는 중?", "<id>는 왜 아직 대기지?" — or when another Claude session asks to register or reset a wait, or when setting up, restarting or debugging the 10-minute wait-check loop, the 대기 보드 artifact, or its Slack notifications.
---

# Waits watcher

Things the user waits on from other people live in one place: the **대기 보드** artifact's database. A loop in
the pod runs a headless Sonnet check every 10 minutes; it reads every open wait, checks it read-only, writes the
result back, and the loop posts a Slack message when one is done. Interactive sessions only register, reset and
answer about waits.

Picture: `references/how-it-works.html` (open it in a browser, or publish it as an artifact).

| Who | Model | Reads |
|---|---|---|
| Any interactive session (registers, resets, answers) | session model | this file |
| `claude -p` check run, every 10 min | Sonnet | `references/check-prompt.md` |
| `scripts/waits.sh loop` | none (bash) | — |
| Board page | none (browser) | the database |

## The database

Board: `ART_URL` in `~/waits/config.env` (`grep ART_URL ~/waits/config.env`). Load the
`ArtifactData` tool (ToolSearch `select:ArtifactData`) and use it on that URL.

- `waits/<id>`: one document per wait (`w<MMDDHHMMSS><2 digits>`) or to-do (`t…`, `kind` "todo").
- `meta/status`: last run time and summary. `meta/sessions`: session list for the board's to-do picker.

A wait document:

| Field | Value |
|---|---|
| `id` | `w` + `MMDDHHMMSS` (now) + 2 random digits, e.g. `w111920051842` |
| `session_id`, `session`, `session_title` | see "Finding the session" below; `session` = messaging name, else the title |
| `title` | one line, Korean, says who and what |
| `kind` | `jira-comment` · `pr-comment` · `slack-thread` · `artifact-comment` · `gh-run` · `other`. A PR state wait (merge, close, review decision) is `pr-comment` with the state spelled out in `done_when` |
| `url`, `target` | the link, and exactly what to read (comment id, thread ts, page id, PR numbers, the `gh` command) |
| `since` | **starts with ISO 8601 with offset** (a suffix like ` (다시 대기)` is fine). For a reply: the timestamp of the comment being answered. For a state change (merge, release, run): when the user asked |
| `baseline` | what is already there, so the checker does not re-report it |
| `done_when` | the condition in plain words; say what the notification should mention |
| `requester` | who or what is being waited on ("철수", "영희 · 개발 이슈 생성") |
| `created_at` now, `errors` 0, `status` "open" | |

**Finding the session.** `python3 -I scripts/sessions.py "<name>"` matches a live session's exact messaging
name, id or UI title. When it returns `session_id: null` (the session is closed, or the user gave a loose name
like "123"), search transcripts for the title:
`grep -l '"customTitle":"<name>"' ~/.claude/projects/*/*.jsonl` (or grep the ticket/PR number), take the file
name as `session_id`, and use the title for `session` and `session_title`. Ask the user only when nothing fits.
| `memos` (optional) | `[{mid, at, text}]` — the user's notes |
| `notify_session` (optional) | default true (missing = true): when done, the check run sends the session `[대기 완료] 대기가 끝났으니 확인해: …`. Set false only when the user says not to |

`status` is exactly one of `open` · `done` · `stuck` · `cancelled`. Never write anything else ("pending" is
what a check *reports*, not a status; a document with another status is never checked).

## Recipes

**Register a wait**
1. Resolve the session and find the real target (fetch the PR/comment/thread to get ids and the timestamp
   `since` should be). Ask the named session with SendMessage only when the target is unclear.
2. `ArtifactData set` the document (new doc: no `if_version`).
3. Run `bash ~/waits/waits.sh check <id>` — the awaited thing may already have happened — then read the doc back
   and report its `last_detail`.

**Reset ("다시 대기", or a session reports it handled everything up to now)** — `get` the doc, then `update` with
its `version` as `if_version`: `status` "open", `closed_at` null, `errors` 0, `session_notified` null,
`session_notify_error` null, `session_notify_via` null, `since` and `reopened_at` = now
(ISO), plus a new `baseline`/`done_when` when the threshold moved (e.g. "page v25 or later"). Keep `memos`.
A session that keeps resetting the same wait can do this itself; it does not need to go through another session.

**Close** — `status` "cancelled", `closed_at` now. **To-do** — `kind` "todo", `t…` id, `title`, optional
`session…`/`url`/`memos`; never checked. **Delete** — the board's × archives (`deleted_at`); the check run purges
after 24 h. Do not `delete` documents yourself unless the user asks.

**Receiving "[대기 완료] 대기가 끝났으니 확인해: …"** — that is this session's own wait finishing. Do what the
user would have asked on arrival: check the result it names (read the PR, ticket, thread or page), report what
changed and what is next, then stop. Anything outward-facing (approving, commenting, merging, posting) still
needs the user's go-ahead.

**"뭐 기다리는 중?"** — `query` `waits` where `status == "open"`; answer grouped by session, with `last_detail`.

**"<id>는 왜 아직 대기지?"** — read the doc, then check its target yourself. If the checker missed it, fix the
prompt (`references/check-prompt.md`) rather than only closing the doc, then close it and send the notification
by hand: `bash ~/waits/waits.sh notify '<text>'`.

Every write to an existing document needs `if_version` from a read; on a conflict, re-read and redo.

## Operating the loop

State lives in `~/waits/` (`WAITS_HOME`): `loop.log`, `loop.pid`, `fail.count`, `webhook.url` (secret, mode
600 — never print it), optional `config.env` (`ART_URL`, `JIRA_CLOUD_ID`, `USER_SLACK_ID`, `GH_LOGIN`,
`DEFAULT_REPO`, `MODEL`, `INTERVAL`; template `scripts/config.env.example`).

```bash
bash ~/waits/waits.sh status          # running? last three runs
bash ~/waits/waits.sh start | stop    # setsid loop; dies on pod restart — ask the user before restarting
bash ~/waits/waits.sh check [id]      # one tick now
```

- A run that cannot reach the database increments `fail.count`; at 18 (3 h) the loop posts "[대기 루프 실패]".
- Per-wait errors are counted in the doc; at 18 the checker marks it `stuck` and notifies.
- A session message whose session is not running is delivered by resuming that session headless
  (`claude -p --resume <session_id>`, read-only tools only, never while a live process holds it); the doc gets
  `session_notify_via` "wake". Sessions are found by `session_id` and addressed by the socket of their newest live process (names change, and two processes can share a name). If delivery fails,
  the message waits in `~/waits/session-queue.json` and is retried every tick, or now with `waits.sh flush`:
  sent if the session is running, woken if not (3 wake tries, 24 h at most).
- The board page source is `scripts/board.html`; republish it to the board URL after editing.
- Notifications go through the webhook app because a Slack message the user's own account posts never
  notifies them; never use the Slack MCP send tool for this.

**New user setup**
1. Publish `scripts/board.html` as an artifact with capabilities `{db:{}, user:{}}` (Artifact tool, `icon`
   "list"); note its URL.
2. `mkdir -p ~/waits && cp scripts/config.env.example ~/waits/config.env`, fill it in, `chmod 600` it.
3. Create a Slack app with an incoming webhook into the channel you want, and write its URL to
   `~/waits/webhook.url` (`chmod 600`). Posting through an app is what makes Slack notify you.
4. `bash ~/.claude/skills/waits-watcher/scripts/waits.sh start`, then register a first wait to check the path.

Needs: Claude Code CLI (`claude -p` with the ArtifactData tool), `jq`, `curl`, `gh` (logged in), python3, and
the claude.ai connectors for the sources you wait on (Atlassian, Slack, Claude Docs).

## Common mistakes

| Mistake | Effect |
|---|---|
| `status` "pending" or any value outside the four | the checker never picks it up |
| `since` as prose ("Jira 100217 게시 시각") | the checker guesses the cutoff |
| `since` = registration time | misses the reply that came before you registered |
| Slack read with `oldest` | the API drops replies; the checker reads the whole thread and compares ts |
| Write without `if_version` | refused, or overwrites the user's edit on the page |
