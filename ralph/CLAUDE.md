# Ralph Agent Instructions

You are an autonomous coding agent working on a software project.

## Your Task

> **Token budget — read only what you need.** `prd.json` (~140 KB, ~96 stories) and `progress.txt`
> (grows ~4 KB per story) are too big to read every iteration. Never `Read`/`cat` either file whole.
> Use `ralph/story.js` for the PRD, and append to `progress.txt` with a shell heredoc (the Edit tool
> would force you to read the whole file first).

1. Run `node ralph/story.js next` (from the repo root). It prints `branchName`, the PRD `description`
   and the **highest priority** story with `passes: false` — that is the story you work on. If it
   prints `ALL_COMPLETE`, skip to the Stop Condition.
2. Read `ralph/patterns.md` in full — the accumulated Codebase Patterns. Do NOT read `progress.txt`;
   it is a human-facing history log. Only if the story's `notes` field is non-empty (a retry), run
   `grep -n '^## .* - <Story ID>' ralph/progress.txt` and read just those entries with offset/limit.
3. Check you're on the correct branch from PRD `branchName`. If not, check it out or create from main.
4. (Step 1 already picked the story.)
5. Record the review base before touching anything: `BASE=$(git rev-parse HEAD)`. Write the SHA
   down — step 9 needs it, and it must be the commit *before* this story's first change.
6. If the PRD `description` names a spec file and a ledger, read the spec and the ledger rows whose
   IDs this story lists. Every change you make must trace to one of those rows; do not fix things
   the story does not list, even if you notice them — note them in `progress.txt` instead.
   The spec and ledger are large (hundreds of KB): use Grep to locate the story's `ledgerIds` rows and
   the spec sections they need, then Read only those ranges — don't read either file whole.
7. Implement that single user story
8. Run quality checks: `bash scripts/validate.sh` from the repo root must exit 0. If checks pass,
   commit ALL changes with message: `feat: [Story ID] - [Story Title]`
9. **Review.** Invoke the `code-review` skill with fixed point `BASE` and pass the spec file and the
   ledger as the spec source. Tell it: the Spec sub-agent must WebFetch every source URL cited by
   the ledger rows in this story and confirm (a) the quoted text really appears on that page and
   (b) the guide's new wording agrees with it. A quote that cannot be found is a finding.
10. If the review has findings, fix them, re-run `bash scripts/validate.sh`, commit
    `fix: [Story ID] - address review`, and review again from the same `BASE`.
    **At most 2 review rounds.** If findings remain after round 2, do NOT set `passes: true`:
    write the remaining findings into the story's `notes` with
    `node ralph/story.js note <Story ID> <<'EOF' ... EOF` (notes come from stdin), commit that, log it in
    `progress.txt`, and end the iteration (a human will look at it).
11. Update `ralph/patterns.md` and CLAUDE.md files if you discover reusable patterns (see below)
12. When the review is clean, run `node ralph/story.js pass <Story ID>`
13. Append your progress to `progress.txt` with `cat >> ralph/progress.txt <<'EOF' ... EOF` (not the
    Edit tool), including a short summary of each review round (findings per axis and what you changed)
14. Commit `prd.json`, `progress.txt` (and `patterns.md` if changed) with message:
    `chore: [Story ID] - mark story complete and log progress`

## Progress Report Format

APPEND to progress.txt (never replace, always append):
```
## [Date/Time] - [Story ID]
- What was implemented
- Files changed
- Review rounds (findings per axis, what you changed)
- Learnings (also copied into patterns.md if reusable — see below)
---
```

## Consolidate Patterns

**Future iterations do NOT read `progress.txt`.** Anything a later iteration needs to know must go
into `ralph/patterns.md`, which every iteration reads in full:

- **General, reusable patterns and gotchas** → the matching section of `patterns.md`.
- **A note for a specific later ledger row / story** (e.g. "when fixing P03-008, point back to Part 0")
  → the `## 留給特定帳本列的提醒` section, keyed by ledger ID. When you complete a row listed there,
  delete its reminder.

Every KB in `patterns.md` is paid again on every remaining iteration: **merge into and rewrite
existing bullets instead of appending**, drop anything that is no longer true, and keep story-specific
details in `progress.txt` only.

## Update CLAUDE.md Files

Before committing, check if any edited files have learnings worth preserving in nearby CLAUDE.md files:

1. **Identify directories with edited files** - Look at which directories you modified
2. **Check for existing CLAUDE.md** - Look for CLAUDE.md in those directories or parent directories
3. **Add valuable learnings** - If you discovered something future developers/agents should know:
   - API patterns or conventions specific to that module
   - Gotchas or non-obvious requirements
   - Dependencies between files
   - Testing approaches for that area
   - Configuration or environment requirements

**Examples of good CLAUDE.md additions:**
- "When modifying X, also update Y to keep them in sync"
- "This module uses pattern Z for all API calls"
- "Tests require the dev server running on PORT 3000"
- "Field names must match the template exactly"

**Do NOT add:**
- Story-specific implementation details
- Temporary debugging notes
- Information already in patterns.md / progress.txt

Only update CLAUDE.md if you have **genuinely reusable knowledge** that would help future work in that directory.

## Quality Requirements

- ALL commits must pass your project's quality checks (typecheck, lint, test)
- Do NOT commit broken code
- Keep changes focused and minimal
- Follow existing code patterns

## Browser Testing (If Available)

For any story that changes UI, verify it works in the browser if you have browser testing tools configured (e.g., via MCP):

1. Navigate to the relevant page
2. Verify the UI changes work as expected
3. Take a screenshot if helpful for the progress log

If no browser tools are available, note in your progress report that manual browser verification is needed.

## Stop Condition

After completing a user story, run `node ralph/story.js next`.

If it prints `ALL_COMPLETE`, reply with:
<promise>COMPLETE</promise>

If there are still stories with `passes: false`, end your response normally (another iteration will pick up the next story).

## Important

- Work on ONE story per iteration
- Commit frequently
- Keep CI green
- Read `ralph/patterns.md` before starting; never read `prd.json` or `progress.txt` whole
