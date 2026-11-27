# waits-watcher

A Claude Code skill for things you are waiting on from other people: a PR review, a reply in a Jira or Slack
thread, a design doc revision, a CI run. You tell a Claude session what you are waiting for; a loop runs cheap
probes every 20 minutes, hands only the waits whose probe changed to a headless `claude -p` run (every open wait
once an hour), posts to Slack when one happens and tells the session that registered it.

- `SKILL.md` — what an interactive Claude session reads: how to register, reset, close and list waits.
- `references/check-prompt.md` — the instructions for the unattended check run.
- `references/how-it-works.html` — a diagram of the moving parts.
- `scripts/waits.sh` — the loop (`check | tick | sync | loop | start | stop | status | notify | flush | doctor`).
- `scripts/board.html` — the 대기 보드 page; its artifact database is the only store of waits.
- `scripts/sessions.py` — resolves a session name or id to its current title, and keeps board titles current.
- `scripts/config.env.example` — per-user settings.

Install: `git clone https://github.com/hyeongyun0916/wait-watcher.git ~/.claude/skills/waits-watcher`, then follow
"New user setup" in `SKILL.md`.
The check run uses `--permission-mode auto` with a deny list for every write tool. A registering session that is
no longer running is resumed in auto mode with no tool limits so it can act on the result. Read `scripts/waits.sh`
before you start it, since it acts with your GitHub, Atlassian and Slack access.
