---
name: waits-watcher
description: Use when the user says they are waiting on someone else and wants to be told when it happens — "PROJ-123 철수 답변 대기", "pr-42 리뷰 대기", "다시 대기", "할 일 추가", "뭐 기다리는 중?", "<id>는 왜 아직 대기지?" — or when another Claude session asks to register or reset a wait, or when setting up, restarting or debugging the 10-minute wait-check loop, the 대기 보드 artifact, or its Slack notifications.
---

# Waits watcher

Things the user waits on from other people live in one place: the **대기 보드** artifact's database. A loop in
the pod ticks every 20 minutes: bash probes (`gh api`, file stat) look for changes, and a headless Haiku check
runs only for waits whose probe changed or that have no probe and are under a day old, plus a full check of
every open wait once an hour. The check reads
the wait read-only, writes the result back, and the loop posts a Slack message when one is done. Interactive sessions only register, reset and
answer about waits.

Picture: `references/how-it-works.html` (open it in a browser, or publish it as an artifact).

| Who | Model | Reads |
|---|---|---|
| Any interactive session (registers, resets, answers) | session model | this file |
| `claude -p` check run: on a probe change, for probe-less waits under a day old, on `waits.sh check`, and hourly in full | Haiku | `references/check-prompt.md` |
| delivery and recording runs (session messages) | Haiku | the prompt inside `waits.sh` |
| `scripts/waits.sh loop` (probes every 20 min) | none (bash) | `~/waits/probes.json` |
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
| `session_id`, `session`, `session_title`, `session_cwd` | see "Finding the session" below; `session` = messaging name, else the title; `session_cwd` = the session's working directory (`cwd` from `sessions.py`), shown on the card |
| `title` | one line, Korean, says who and what |
| `kind` | `jira-comment` · `pr-comment` · `slack-thread` · `artifact-comment` · `gh-run` · `other`. A PR state wait (merge, close, review decision) is `pr-comment` with the state spelled out in `done_when` |
| `url`, `target` | the link, and exactly what to read (comment id, thread ts, page id, PR numbers, the `gh` command) |
| `since` | **starts with ISO 8601 with offset** (a suffix like ` (다시 대기)` is fine). For a reply: the timestamp of the comment being answered. For a state change (merge, release, run): when the user asked |
| `baseline` | what is already there, so the checker does not re-report it |
| `done_when` | the condition in plain words, **with every end state, not just the happy one**: a run that ends in failure or is cancelled, a PR closed unmerged, a ticket closed without the reply. Say what the notification should mention for each |
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
0. Check that something is actually pending. A wait can be on another person or on your own work still
   running (a background test, a GPU run, a build); either way, write in `memos` what to do once it is done
   (e.g. the draft to post). A next step the user can take right now — a decision, or a "confirm" that is
   really their own action — is not a wait; hand it to the user. Example: on a design issue the reviewer's
   `[요약]` is confirmed by the assignee creating the development issues, so "reviewer re-confirms the [요약]"
   is not a wait.
1. Resolve the session and find the real target (fetch the PR/comment/thread to get ids and the timestamp
   `since` should be). Ask the named session with SendMessage only when the target is unclear.
2. `ArtifactData set` the document (new doc: no `if_version`).
3. Run `bash ~/waits/waits.sh check <id>` — the awaited thing may already have happened — then read the doc back
   and report its `last_detail`.

**Reset ("다시 대기" from the user, or the user's own action handed the turn back — they replied, pushed, commented)** — never on your own after a `[대기 완료]`: reporting a result is not handling it. `get` the doc, then `update` with
its `version` as `if_version`: `status` "open", `closed_at` null, `errors` 0, `session_notified` null,
`session_notify_error` null, `session_notify_via` null, `reopened_at` = now (ISO), and `since` = the time of
the user's last action that handed the turn back (the reply, re-review request, push or comment, read from the
source), never the time of the reset: the other side may have answered in between, and a `since` after that
answer hides it for good. Unknown → the previous `closed_at`. Plus a new `baseline`/`done_when` when the threshold moved (e.g. "page v25 or later"). Keep `memos`.
Then run `bash ~/waits/waits.sh check <id>`: that check gives the wait its probes, so changes are seen on the
next 20-minute tick instead of at the next hourly full check.
A session that keeps resetting the same wait can do this itself; it does not need to go through another session.

**Close** — `status` "cancelled", `closed_at` now. **To-do** — `kind` "todo", `t…` id, `title`, optional
`session…`/`url`/`memos`; never checked. **Delete** — the board's × archives (`deleted_at`); the check run purges
after 24 h. Do not `delete` documents yourself unless the user asks.

**Receiving "[대기 완료] 대기가 끝났으니 확인해: …"** — that is this session's own wait finishing. Do what the
user would have asked on arrival: check the result it names (read the PR, ticket, thread or page), report what
changed and what is next, then stop. Anything outward-facing (approving, commenting, merging, posting) still
needs the user's go-ahead. **Do not reset the wait.** It stays `done` until the user says "다시 대기" or has
acted on what arrived (posted the reply, pushed); drafting a reply for them is not acting. A reset moves `since`
past what arrived, so the board stops showing that the user still owes a response.
When one wait covers several items and only some move to the user (one PR answered, the others not), the
reset that narrows the wait to the rest must add the user's part as a to-do (`t…`) in the same turn — a
comprehension summary to write, a requester's decision, a reply only they can give. The user reads the board
to tell whose turn it is; a step that lives only in chat looks like "still waiting on someone else"
(seen: three review summaries sat in chat while the board still showed two open waits).

**"뭐 기다리는 중?"** — `query` `waits` where `status == "open"`; answer grouped by session, with `last_detail`.

**"<id>는 왜 아직 대기지?"** — read the doc, then check its target yourself. If the checker missed it, fix the
prompt (`references/check-prompt.md`) rather than only closing the doc, then close it and send the notification
by hand: `bash ~/waits/waits.sh notify '<text>'`.

Every write to an existing document needs `if_version` from a read; on a conflict, re-read and redo.

## Operating the loop

State lives in `~/waits/` (`WAITS_HOME`): `loop.log`, `loop.pid`, `fail.count`, `probes.json`, `full.at`, `full.try`,
`webhook.url` (secret, mode 600 — never print it), optional `config.env` (`ART_URL`, `JIRA_CLOUD_ID`,
`USER_SLACK_ID`, `GH_LOGIN`, `DEFAULT_REPO`, `MODEL`, `HELPER_MODEL`, `INTERVAL`, `FULL_EVERY`, `FRESH_HOURS`; template
`scripts/config.env.example`).

```bash
bash ~/waits/waits.sh status          # running? consecutive database failures, last three runs
bash ~/waits/waits.sh doctor          # can a headless run load ArtifactData and read the board? OK / FAIL: …
bash ~/waits/waits.sh start | stop    # runs doctor, then a setsid loop; dies on pod restart — ask before restarting
bash ~/waits/waits.sh tick            # probes now; Claude only if something changed or a full check is due
bash ~/waits/waits.sh check [id,id]   # Claude check now (all open waits, or those)
bash ~/waits/waits.sh sync            # session name/title/cwd on every doc = sessions.py now (also after each full check)
```

- **Probes.** Each check returns, for every wait still open, structured probes (`{"gh": "repos/…", "jq": …}` or
  `{"file": "/abs/path"}`, never a shell command) and an optional `recheck_at`. The loop keeps them in
  `probes.json`, runs them every tick, and hands Claude only the waits whose fingerprint changed, whose
  `recheck_at` passed, or whose probe failed (at most hourly). Jira, Slack, Confluence and artifact waits have no
  probe: every tick for a day after `reopened_at`/`created_at` (`FRESH_HOURS`), then only the hourly full check. A
  tick with nothing due calls no model at all.
- **Failures are announced, never silent.** A run that cannot reach the database increments `fail.count`; at
  `FAIL_ALERT_AFTER` (2) the loop posts "[대기 루프 실패]" with the run's own explanation, and again every 18
  after. A probe change whose check cannot reach the database posts "[대기 확인 실패]" naming the probe, once per
  change. A failing full check is retried at most hourly (`full.try`) and never keeps the probes from running.
- **ArtifactData needs the entrypoint.** A `claude -p` started outside a Claude Code session gets no
  ArtifactData tool, so every check fails with `db_ok` false. `waits.sh` exports
  `CLAUDE_CODE_ENTRYPOINT=claude-vscode` (`WAITS_ENTRYPOINT` overrides) for its runs, and `start` refuses to
  launch when `doctor` fails. When the loop reports failures, run `doctor` first, then restart the loop: a
  running loop keeps the script and environment it started with, so edits to `waits.sh` apply only after a
  restart.
- Per-wait errors are counted in the doc per check; at 18 the checker marks it `stuck` and notifies.
- A session message whose session is not running is delivered by resuming that session headless
  (`claude -p --resume <session_id>`, in auto mode with no tool limits so it can act on the result (up to 30 min), never while a live process holds it); the doc gets
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
4. `bash ~/.claude/skills/waits-watcher/scripts/waits.sh doctor` must print `OK`; then `… start`, and register
   a first wait to check the path.

Needs: Claude Code CLI (`claude -p` with the ArtifactData tool), `jq`, `curl`, `gh` (logged in), python3, and
the claude.ai connectors for the sources you wait on (Atlassian, Slack, Claude Docs).

## Common mistakes

| Mistake | Effect |
|---|---|
| Wait registered for a step the user can take right now (e.g. "리뷰어 [요약] 재확정 대기" when the assignee confirms by creating dev issues) | the user's task sits blocked behind a wait that never needed anyone else |
| `status` "pending" or any value outside the four | the checker never picks it up |
| `since` as prose ("Jira 100217 게시 시각") | the checker guesses the cutoff |
| `since` = registration time | misses the reply that came before you registered |
| `since` = reset time on "다시 대기" | misses the answer that came between the user's last action and the reset (e.g. approval at 12:07, reset at 12:20: the approval is never seen) |
| Session resets the wait itself after reporting a `[대기 완료]` (no "다시 대기", user has not acted) | the arrival is marked "already reported" and the board shows nothing pending while the user still owes a reply (w112416480140, 11-26: reset twice, user had not replied) |
| Slack read with `oldest` | the API drops replies; the checker reads the whole thread and compares ts |
| Write without `if_version` | refused, or overwrites the user's edit on the page |
| `done_when` names only success ("두 run이 completed") | the checker may hold a failed or cancelled run as pending; list every end state |
| Loop started from a plain shell without the entrypoint, or not restarted after editing `waits.sh` | every check fails with `db_ok` false; probes change but nothing is marked done. `doctor`, then restart |
