#!/usr/bin/env bash
# SessionStart hook: if the Vacuum PCB iCloud documents repo has uncommitted
# changes, nudge Claude to remind the user (once per session, silent if clean).
GD="$HOME/Documents/dev/vacuum-docs"
WT="$HOME/Library/Mobile Documents/iCloud~com~ionini~Vacuum-PCB/Documents"

[ -d "$GD" ] || exit 0
changes="$(git --git-dir="$GD" --work-tree="$WT" status --porcelain 2>/dev/null)" || exit 0
[ -n "$changes" ] || exit 0
count="$(printf '%s\n' "$changes" | grep -c .)"

ctx="The Vacuum PCB design-documents repo (~/Documents/dev/vacuum-docs, working tree in iCloud) has ${count} uncommitted change(s). At a natural break in the conversation, remind the user they can commit their .vpcb design changes: cd into the iCloud Documents folder and run 'git add -A && git commit'. Do not interrupt the current task for this."

# Emit JSON with additionalContext injected into the model's context.
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' \
  "$(printf '%s' "$ctx" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
