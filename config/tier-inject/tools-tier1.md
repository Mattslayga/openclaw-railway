**Tier 1 — Capable Agent**

| Tool | Status | Notes |
|------|--------|-------|
| read | ✅ | Sandboxed to `/data/workspace/` |
| write | ✅ | Sandboxed to `/data/workspace/` |
| edit | ✅ | Sandboxed to `/data/workspace/` |
| apply_patch | ✅ | Sandboxed to `/data/workspace/` |
| exec | ⚠️ | Workspace-scoped: `ls`, `find`, `wc`, `sort`, `uniq`. Arguments are restricted; `git` and content-reading commands are denied. |
| memory_get | ✅ | Reads from `MEMORY.md` and `memory/` |
| memory_search | ✅ | Semantic search over memory |
| web_fetch | ✅ | GET requests only, no POST |
| web_search | ✅ | Web search |
| image | ✅ | Image analysis (vision) |
| cron | ✅ | Scheduled tasks |
| browser | ❌ | Blocked |
| process | ❌ | Blocked |
| sessions_spawn | ❌ | Blocked |
| agents_list | ❌ | Blocked |
| nodes | ❌ | Blocked |
| gateway | ❌ | Blocked |

**File access:** All file tools (read/write/edit) are sandboxed to your workspace. Paths outside `/data/workspace/` are rejected by the gateway.
**Exec note:** Commands not in the allowlist are denied. No approval queue.
