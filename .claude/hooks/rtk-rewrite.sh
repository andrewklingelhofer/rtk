#!/bin/bash
# RTK auto-rewrite hook for Claude Code PreToolUse:Bash
# Prepends "rtk" to recognized commands for token-optimized output.
# Strips runner prefixes (npx, pnpm-as-launcher, python -m, uv) first.
#
# Read-only commands get permissionDecision: allow (they were already
# auto-allowed by Claude Code, so no security change). Mutating commands
# go through normal permission checks.

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

# Skip heredocs
case "$CMD" in
  *'<<'*) exit 0 ;;
esac

# Handle "cd <dir> && <command>" prefix that Claude Code adds when
# specifying a working directory. We rewrite the last segment only.
PREFIX=""
ACTUAL_CMD="$CMD"
if echo "$CMD" | grep -qF '&&'; then
  PREFIX=$(echo "$CMD" | sed -E 's/(.*&&[[:space:]]*).*/\1/')
  ACTUAL_CMD=$(echo "$CMD" | sed -E 's/.*&&[[:space:]]*//')
fi

# Handle "git -C <path> <subcmd>" by converting to "cd <path> && git <subcmd>"
# rtk's git parser doesn't support -C, but the prefix approach works fine.
if echo "$ACTUAL_CMD" | grep -qE '^git[[:space:]]+-C[[:space:]]+'; then
  GIT_C_PATH=$(echo "$ACTUAL_CMD" | sed -E 's/^git[[:space:]]+-C[[:space:]]+([^[:space:]]+)[[:space:]]+.*/\1/')
  GIT_REST=$(echo "$ACTUAL_CMD" | sed -E 's/^git[[:space:]]+-C[[:space:]]+[^[:space:]]+[[:space:]]+//')
  PREFIX="${PREFIX}cd $GIT_C_PATH && "
  ACTUAL_CMD="git $GIT_REST"
fi

# Skip if the actual command already uses rtk
case "$ACTUAL_CMD" in
  rtk\ *) exit 0 ;;
esac

REWRITTEN=""
SAFE=false  # Whether the original command is read-only / auto-allowed

# --- Strip runner prefixes first, then prepend rtk ---
# npx <tool> → rtk <tool> (npx is just a launcher)
if echo "$ACTUAL_CMD" | grep -qE '^npx\s+'; then
  REWRITTEN=$(echo "$ACTUAL_CMD" | sed 's/^npx /rtk /')

# pnpm as launcher for specific tools (not pnpm's own commands)
elif echo "$ACTUAL_CMD" | grep -qE '^pnpm\s+(tsc|lint|test|vitest|playwright)(\s|$)'; then
  REWRITTEN=$(echo "$ACTUAL_CMD" | sed 's/^pnpm /rtk /')

# python -m pytest → rtk pytest
elif echo "$ACTUAL_CMD" | grep -qE '^python\s+-m\s+pytest(\s|$)'; then
  REWRITTEN=$(echo "$ACTUAL_CMD" | sed 's/^python -m /rtk /')

# uv pip → rtk pip (uv is just a launcher for pip)
elif echo "$ACTUAL_CMD" | grep -qE '^uv\s+pip\s+'; then
  REWRITTEN=$(echo "$ACTUAL_CMD" | sed 's/^uv /rtk /')

# --- Direct commands: just prepend rtk ---
# NOTE: This broadly matches the top-level command (e.g. "git"), so ALL
# subcommands get routed through rtk — even ones rtk doesn't specifically
# filter (e.g. git checkout, go get). Those hit rtk's passthrough handlers
# and run unmodified. Trivial overhead, keeps this hook simple.
elif echo "$ACTUAL_CMD" | grep -qE '^(git|gh|cargo|cat|grep|rg|ls|find|tree|diff|docker|kubectl|curl|wget|vitest|tsc|eslint|prettier|playwright|prisma|npm|pnpm|pytest|ruff|pip|go|golangci-lint)(\s|$)'; then
  REWRITTEN="rtk $ACTUAL_CMD"

# head -N file → rtk cat file --max-lines N (special arg transform)
elif echo "$ACTUAL_CMD" | grep -qE '^head\s+-[0-9]+\s+'; then
  LINES=$(echo "$ACTUAL_CMD" | sed -E 's/^head +-([0-9]+) +.+$/\1/')
  FILE=$(echo "$ACTUAL_CMD" | sed -E 's/^head +-[0-9]+ +(.+)$/\1/')
  REWRITTEN="rtk cat $FILE --max-lines $LINES"
  SAFE=true
elif echo "$ACTUAL_CMD" | grep -qE '^head\s+--lines=[0-9]+\s+'; then
  LINES=$(echo "$ACTUAL_CMD" | sed -E 's/^head +--lines=([0-9]+) +.+$/\1/')
  FILE=$(echo "$ACTUAL_CMD" | sed -E 's/^head +--lines=[0-9]+ +(.+)$/\1/')
  REWRITTEN="rtk cat $FILE --max-lines $LINES"
  SAFE=true
fi

# No match — let the command run unmodified
if [ -z "$REWRITTEN" ]; then
  exit 0
fi

# Re-attach the prefix
REWRITTEN="${PREFIX}${REWRITTEN}"

# Determine if the original command is read-only (auto-allowed by Claude Code).
# These get permissionDecision: allow since they were already allowed anyway.
# Mutating commands (git push, git commit, curl, docker, etc.) go through
# normal permission checks.
if [ "$SAFE" = false ]; then
  case "$ACTUAL_CMD" in
    # Git read-only
    git\ status*|git\ log*|git\ diff*|git\ show*|git\ branch*|git\ stash\ list*|git\ remote*)
      SAFE=true ;;
    # File read-only
    cat\ *|grep\ *|rg\ *|ls*|find\ *|tree*|diff\ *|head\ *)
      SAFE=true ;;
    # Package info (read-only)
    pnpm\ list*|pnpm\ ls*|pnpm\ outdated*|pip\ list*|pip\ show*|pip\ outdated*)
      SAFE=true ;;
    # GitHub CLI read-only
    gh\ pr\ view*|gh\ pr\ list*|gh\ pr\ diff*|gh\ issue\ view*|gh\ issue\ list*|gh\ run\ view*|gh\ run\ list*)
      SAFE=true ;;
    # Container read-only
    docker\ ps*|docker\ images*|docker\ logs*|kubectl\ get*|kubectl\ logs*)
      SAFE=true ;;
    # Go read-only
    go\ vet*|golangci-lint*)
      SAFE=true ;;
    # Linter/formatter checks (read-only)
    eslint\ *|ruff\ check*|prettier\ --check*)
      SAFE=true ;;
  esac
fi

# Build the updated tool_input with all original fields preserved, only command changed
ORIGINAL_INPUT=$(echo "$INPUT" | jq -c '.tool_input')
UPDATED_INPUT=$(echo "$ORIGINAL_INPUT" | jq --arg cmd "$REWRITTEN" '.command = $cmd')

if [ "$SAFE" = true ]; then
  # Read-only command: auto-approve (was already auto-allowed before rewrite)
  jq -n \
    --argjson updated "$UPDATED_INPUT" \
    '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": "RTK rewrite of read-only command",
        "updatedInput": $updated
      }
    }'
else
  # Mutating command: let normal permission rules decide
  jq -n \
    --argjson updated "$UPDATED_INPUT" \
    '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": $updated
      }
    }'
fi
