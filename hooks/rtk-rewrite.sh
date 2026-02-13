#!/bin/bash
# RTK auto-rewrite hook for Claude Code PreToolUse:Bash
# Prepends "rtk" to recognized commands for token-optimized output.
# Strips runner prefixes (npx, pnpm-as-launcher, python -m, uv) first.

# Guards: skip silently if dependencies missing
if ! command -v rtk &>/dev/null || ! command -v jq &>/dev/null; then
  exit 0
fi

set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$CMD" ]; then
  exit 0
fi

# Skip if already using rtk
case "$CMD" in
  rtk\ *|*/rtk\ *) exit 0 ;;
esac

# Skip heredocs
case "$CMD" in
  *'<<'*) exit 0 ;;
esac

REWRITTEN=""

# --- Strip runner prefixes first, then prepend rtk ---
# npx <tool> → rtk <tool> (npx is just a launcher)
if echo "$CMD" | grep -qE '^npx\s+'; then
  REWRITTEN=$(echo "$CMD" | sed 's/^npx /rtk /')

# pnpm as launcher for specific tools (not pnpm's own commands)
elif echo "$CMD" | grep -qE '^pnpm\s+(tsc|lint|test|vitest|playwright)(\s|$)'; then
  REWRITTEN=$(echo "$CMD" | sed 's/^pnpm /rtk /')

# python -m pytest → rtk pytest
elif echo "$CMD" | grep -qE '^python\s+-m\s+pytest(\s|$)'; then
  REWRITTEN=$(echo "$CMD" | sed 's/^python -m /rtk /')

# uv pip → rtk pip (uv is just a launcher for pip)
elif echo "$CMD" | grep -qE '^uv\s+pip\s+'; then
  REWRITTEN=$(echo "$CMD" | sed 's/^uv /rtk /')

# --- Direct commands: just prepend rtk ---
elif echo "$CMD" | grep -qE '^(git|gh|cargo|cat|grep|rg|ls|find|tree|diff|docker|kubectl|curl|wget|vitest|tsc|eslint|prettier|playwright|prisma|npm|pnpm|pytest|ruff|pip|go|golangci-lint)(\s|$)'; then
  REWRITTEN="rtk $CMD"

# head -N file → rtk cat file --max-lines N (special arg transform)
elif echo "$CMD" | grep -qE '^head\s+-[0-9]+\s+'; then
  LINES=$(echo "$CMD" | sed -E 's/^head +-([0-9]+) +.+$/\1/')
  FILE=$(echo "$CMD" | sed -E 's/^head +-[0-9]+ +(.+)$/\1/')
  REWRITTEN="rtk cat $FILE --max-lines $LINES"
elif echo "$CMD" | grep -qE '^head\s+--lines=[0-9]+\s+'; then
  LINES=$(echo "$CMD" | sed -E 's/^head +--lines=([0-9]+) +.+$/\1/')
  FILE=$(echo "$CMD" | sed -E 's/^head +--lines=[0-9]+ +(.+)$/\1/')
  REWRITTEN="rtk cat $FILE --max-lines $LINES"
fi

# No match — let the command run unmodified
if [ -z "$REWRITTEN" ]; then
  exit 0
fi

# Build the updated tool_input with all original fields preserved, only command changed
ORIGINAL_INPUT=$(echo "$INPUT" | jq -c '.tool_input')
UPDATED_INPUT=$(echo "$ORIGINAL_INPUT" | jq --arg cmd "$REWRITTEN" '.command = $cmd')

# Output the rewrite instruction (no permissionDecision — let the user's
# existing permission rules decide whether to allow the rewritten command)
jq -n \
  --argjson updated "$UPDATED_INPUT" \
  '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "updatedInput": $updated
    }
  }'
