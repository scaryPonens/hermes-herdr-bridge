# Diagnostic Patterns

Quick recipes for common "is X working?" questions against a `herdr`-managed agent.

## "Does this agent have GitHub access?"

Useful when a Codex or Claude pane is in the user's repo and the user asks about PR / issue / repo capabilities.

```bash
# 1. Confirm identity the agent thinks it has (Codex connector)
herdr agent prompt <pane_id> "Call codex_apps.github.get_user_login({}) and codex_apps.github.list_installations({}). Also run: gh auth status, and git remote -v. Report all four outputs verbatim and whether each path returned a real account, no installs, or an error."

# 2. Wait for the agent to settle, then read back
herdr agent wait <pane_id> --timeout 120000
herdr agent read <pane_id> | tail -60
```

**Expected triage outcomes** (from a real session against a Voltus workspace, user `scaryPonens`):

| Signal | Meaning |
|---|---|
| `codex_apps.github.get_user_login` returns a username | Connector is authenticated; identity is known |
| `list_installations` returns `[]` (empty) | Connector is bound but no org-level GitHub App installations — only personal repos visible |
| `get_repo` on a private repo returns `404 Not Found` | Connector cannot reach the private org repo; the GitHub App isn't installed there |
| `gh auth status` says `Failed to log in to github.com account X` | Local `gh` CLI token is expired/revoked — needs `gh auth login -h github.com` |
| `git remote -v` shows `git@github.com:org/repo.git` | SSH key is configured — agent could push/pull via SSH even without `gh` or the connector, but should not test silently |

Always frame the diagnosis as **partial / full / none** rather than a binary. The pattern from this session:

> "Yes — partially. Connected as `<user>`, 89 ops exposed, but the private org repo 404s and `gh` token is invalid. No changes made."

## "What task is actually running in this pane?"

When `agent_status: working` and you need to confirm it's the task the user asked about (not a stale tab):

```bash
# Read the last 40 lines of the terminal
herdr agent read <pane_id> | tail -40

# Look for these markers in the status bar / footer:
#   ⏺ task description
#   ⎿  $ command (elapsed time)
#   ● / Eval 0 with skill   <-- Claude skill evaluation in progress
#   *  / Eval N with skill  <-- later iteration
#   ✳  / ↳ title           <-- title bar (working / blocked / idle markers)
```

Useful terminal-title glyphs (Claude Code + Codex):
- `✳` spinning = working
- `◑` half = waiting / partial
- `✳` stopped = blocked / idle
- `⠙` spinner = Codex working

The `terminal_title` field on `herdr agent list` shows the human-readable task description and updates live.

## "How do I tell the user the agent is done vs. timed out?"

The wait process exits with **two distinct outputs**:

| Result | Output | Meaning |
|---|---|---|
| Agent settled | `{"id":"cli:agent:wait","result":{"type":"agent_info", "agent":{"agent_status":"idle"\|"done"\|"blocked", ...}}}` | Done — read pane and reply |
| Wait timed out | `{"error":{"code":"timeout","message":"timed out waiting for agent status"},"id":"cli:agent:wait"}` | The wait process hit its `--timeout`, NOT the agent. Re-check status before declaring done. |

Always re-run `herdr agent list` after a timeout notification and only restart the wait (or report completion) based on the live `agent_status`.

## "Did my `agent prompt` actually land?"

`herdr agent prompt` returns `{"type":"agent_prompted"}` even when the prompt silently failed to reach the agent — a leftover background shell from a previous turn (e.g. an `until [...] do sleep N` tail watcher, a `caffeinate -i -t 300` foreground process, or any still-running subprocess) can swallow the input. Detecting it:

```bash
# Before submitting, capture
herdr agent get <pane_id> | jq '.result.agent | {revision, state_change_seq, agent_status}'

# Submit
herdr agent prompt <pane_id> "the prompt text"

# ~3s later, check again — if revision/state_change_seq unchanged and status still idle, it dropped
herdr agent get <pane_id> | jq '.result.agent | {revision, state_change_seq, agent_status}'
```

If dropped, recover in order of preference:
1. **Send a shorter prompt.** Observed in practice: a 6-word prompt `"Run the review-prs skill on my open PRs"` landed cleanly where a paragraph-long detailed prompt was dropped.
2. **Cycle a short wait to drain the leftover shell**, then retry: `herdr agent wait <pane> --timeout 10000`.
3. **Clear the input buffer explicitly:** `herdr pane send-keys --pane <p> ctrl+u ctrl+a ctrl+k`, then `herdr agent prompt` again. The visual buffer (`❯ ...`) may not visibly clear even on success — that's a UI artifact of Claude/Codex, not a sign of failure. Trust the revision/state_change_seq check, not the display.