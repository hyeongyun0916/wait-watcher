"""Resolve a Claude session's current UI title and messaging name.

UI title = the transcript's latest customTitle (set by /rename), else its latest aiTitle.
Messaging name = `name` in ~/.claude/sessions/<pid>.json (what ListAgents shows).

Working directory = `cwd` of the newest live process, else the last `cwd` the transcript records.

CLI: python3 sessions.py <session-id | messaging name>  -> JSON {session_id, name, title, cwd}
"""
import glob
import json
import os
import re
import sys

HOME = os.path.expanduser("~")
_TITLE_RE = re.compile(rb'"(customTitle|aiTitle)":"((?:[^"\\]|\\.)*)"')
_CWD_RE = re.compile(rb'"cwd":"((?:[^"\\]|\\.)*)"')
_cache = {}


def _session_files():
    for f in glob.glob(os.path.join(HOME, ".claude/sessions/*.json")):
        try:
            with open(f) as fh:
                yield json.load(fh)
        except (OSError, ValueError):
            continue


def _transcript(session_id):
    hits = glob.glob(os.path.join(HOME, ".claude/projects/*", f"{session_id}.jsonl"))
    return max(hits, key=os.path.getmtime) if hits else None


def title_of(session_id):
    path = _transcript(session_id)
    if not path:
        return None
    mtime = os.path.getmtime(path)
    if _cache.get(path, (None,))[0] == mtime:
        return _cache[path][1]
    custom = ai = None
    with open(path, "rb") as fh:
        for line in fh:
            if b"Title\":" not in line:
                continue
            for kind, raw in _TITLE_RE.findall(line):
                val = json.loads(b'"' + raw + b'"')
                if kind == b"customTitle":
                    custom = val
                else:
                    ai = val
    title = custom or ai
    _cache[path] = (mtime, title)
    return title


def cwd_of(session_id):
    procs = [s for s in _session_files() if s.get("sessionId") == session_id and s.get("cwd")]
    if procs:
        return max(procs, key=lambda s: s.get("updatedAt") or 0)["cwd"]
    path = _transcript(session_id)
    if not path:
        return None
    cwd = None
    with open(path, "rb") as fh:
        for line in fh:
            m = _CWD_RE.search(line)
            if m:
                cwd = json.loads(b'"' + m.group(1) + b'"')
    return cwd


def name_of(session_id):
    names = [s for s in _session_files() if s.get("sessionId") == session_id]
    names.sort(key=lambda s: s.get("updatedAt") or 0, reverse=True)
    return names[0].get("name") if names else None


def live_sessions():
    """Running sessions (pid alive) as {session_id, name, title, cwd}, newest first."""
    seen, out = set(), []
    files = sorted(_session_files(), key=lambda s: s.get("updatedAt") or 0, reverse=True)
    for s in files:
        sid, pid = s.get("sessionId"), s.get("pid")
        if not sid or sid in seen:
            continue
        try:
            os.kill(int(pid), 0)
        except (OSError, TypeError, ValueError):
            continue
        seen.add(sid)
        out.append({"session_id": sid, "name": s.get("name"), "title": title_of(sid) or s.get("name"),
                    "cwd": s.get("cwd")})
    return out


def resolve(key):
    """key = session id or messaging name."""
    sid = key
    if not re.fullmatch(r"[0-9a-f-]{36}", key):
        cands = [s for s in _session_files() if s.get("name") == key]
        cands.sort(key=lambda s: s.get("updatedAt") or 0, reverse=True)
        sid = cands[0].get("sessionId") if cands else None
    if not sid:  # fall back to the UI title (what the user sees)
        for t in live_sessions():
            if t["title"] == key:
                sid = t["session_id"]
                break
    if not sid:
        return {"session_id": None, "name": key, "title": None, "cwd": None}
    return {"session_id": sid, "name": name_of(sid) or key, "title": title_of(sid), "cwd": cwd_of(sid)}


def diff(snap_dir):
    """[{id, fields}] that bring each saved waits document's session fields up to date."""
    out = []
    for f in sorted(os.listdir(snap_dir)):
        with open(os.path.join(snap_dir, f), encoding="utf-8") as fh:
            doc = json.load(fh)
        sid = doc.get("session_id")
        if not isinstance(sid, str) or not re.fullmatch(r"[0-9a-f-]{36}", sid) or doc.get("deleted_at"):
            continue
        now = {"session": name_of(sid), "session_title": title_of(sid), "session_cwd": cwd_of(sid)}
        fields = {k: v for k, v in now.items() if v and v != doc.get(k)}
        if fields:
            out.append({"id": doc.get("id") or f[:-5], "fields": fields})
    return out


if __name__ == "__main__":
    if sys.argv[1] == "--diff":
        print(json.dumps(diff(sys.argv[2]), ensure_ascii=False))
    else:
        print(json.dumps(resolve(sys.argv[1]), ensure_ascii=False))
