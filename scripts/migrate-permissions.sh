#!/bin/bash
# Adds "rtk "-prefixed permission rules for existing Bash rules that
# match commands rtk intercepts.
#
# Since rtk just prepends "rtk " to commands (no renaming), the mapping
# is: Bash(X:*) → Bash(rtk X:*)
#
# Usage: ./migrate-permissions.sh [--dry-run]

set -euo pipefail

SETTINGS="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

if [[ ! -f "$SETTINGS" ]]; then
  echo "Error: $SETTINGS not found" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required" >&2
  exit 1
fi

# Commands rtk intercepts (must match the hook's grep pattern)
RTK_COMMANDS="git|gh|cargo|cat|grep|rg|ls|find|tree|diff|docker|kubectl|curl|wget|vitest|tsc|eslint|prettier|playwright|prisma|npm|pnpm|pytest|ruff|pip|go|golangci-lint"

EXISTING=$(jq -r '.permissions.allow[]' "$SETTINGS" 2>/dev/null)
NEW_RULES=()

while IFS= read -r rule; do
  [[ -z "$rule" ]] && continue
  # Only Bash rules, skip if already rtk-prefixed
  [[ "$rule" != Bash\(* ]] && continue
  [[ "$rule" == Bash\(rtk\ * ]] && continue

  # Extract command inside Bash(...)
  inner="${rule#Bash(}"
  inner="${inner%)}"

  # Check if it starts with a command rtk handles
  if echo "$inner" | grep -qE "^($RTK_COMMANDS)(\s|:|$)"; then
    new_rule="Bash(rtk $inner)"
    # Skip if already exists
    if echo "$EXISTING" | grep -qF "$new_rule"; then
      continue
    fi
    NEW_RULES+=("$new_rule")
  fi
done <<< "$EXISTING"

if [[ ${#NEW_RULES[@]} -eq 0 ]]; then
  echo "No new rules needed — everything is already covered."
  exit 0
fi

echo "Rules to add:"
for rule in "${NEW_RULES[@]}"; do
  echo "  + $rule"
done

if $DRY_RUN; then
  echo ""
  echo "(dry run — no changes made)"
  exit 0
fi

# Build jq filter to append all new rules
JQ_FILTER='.permissions.allow += ['
first=true
for rule in "${NEW_RULES[@]}"; do
  $first || JQ_FILTER+=','
  first=false
  JQ_FILTER+="\"$rule\""
done
JQ_FILTER+=']'

cp "$SETTINGS" "${SETTINGS}.bak"
jq "$JQ_FILTER" "$SETTINGS" > "${SETTINGS}.tmp"
mv "${SETTINGS}.tmp" "$SETTINGS"

echo ""
echo "Added ${#NEW_RULES[@]} rules to $SETTINGS"
echo "Backup at ${SETTINGS}.bak"
