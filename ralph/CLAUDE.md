# Ralph Agent Instructions

You are an autonomous coding agent working on a software project.

## Your Task

1. Read the PRD at `prd.json` (in the same directory as this file)
2. Read the progress log at `progress.txt` (check Codebase Patterns section first)
3. Check you're on the correct branch from PRD `branchName`. If not, check it out or create from main.
4. Pick the **highest priority** user story where `passes: false`
5. Record the review base before touching anything: `BASE=$(git rev-parse HEAD)`. Write the SHA
   down — step 9 needs it, and it must be the commit *before* this story's first change.
6. If the PRD `description` names a spec file and a ledger, read the spec and the ledger rows whose
   IDs this story lists. Every change you make must trace to one of those rows; do not fix things
   the story does not list, even if you notice them — note them in `progress.txt` instead.
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
    write the remaining findings into the story's `notes` field in `prd.json`, commit that, log it in
    `progress.txt`, and end the iteration (a human will look at it).
11. Update CLAUDE.md files if you discover reusable patterns (see below)
12. When the review is clean, update the PRD to set `passes: true` for the completed story
13. Append your progress to `progress.txt`, including a short summary of each review round
    (findings per axis and what you changed)
14. Commit `prd.json` and `progress.txt` with message: `chore: [Story ID] - mark story complete and log progress`

## Progress Report Format

APPEND to progress.txt (never replace, always append):
```
## [Date/Time] - [Story ID]
- What was implemented
- Files changed
- **Learnings for future iterations:**
  - Patterns discovered (e.g., "this codebase uses X for Y")
  - Gotchas encountered (e.g., "don't forget to update Z when changing W")
  - Useful context (e.g., "the evaluation panel is in component X")
---
```

The learnings section is critical - it helps future iterations avoid repeating mistakes and understand the codebase better.

## Consolidate Patterns

If you discover a **reusable pattern** that future iterations should know, add it to the `## Codebase Patterns` section at the TOP of progress.txt (create it if it doesn't exist). This section should consolidate the most important learnings:

```
## Codebase Patterns
- Example: Use `sql<number>` template for aggregations
- Example: Always use `IF NOT EXISTS` for migrations
- Example: Export types from actions.ts for UI components
```

Only add patterns that are **general and reusable**, not story-specific details.

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
- Information already in progress.txt

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

After completing a user story, check if ALL stories have `passes: true`.

If ALL stories are complete and passing, reply with:
<promise>COMPLETE</promise>

If there are still stories with `passes: false`, end your response normally (another iteration will pick up the next story).

## Important

- Work on ONE story per iteration
- Commit frequently
- Keep CI green
- Read the Codebase Patterns section in progress.txt before starting
