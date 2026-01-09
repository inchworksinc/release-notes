#!/bin/bash
set -e

# ============================================================================
# Configuration
# ============================================================================

BUILD_TYPE="${BUILD_TYPE}"  # 'daily' or 'release'
OUTPUT_FILE="${OUTPUT_FILE}"
OUTPUT_PATH="release-notes/${OUTPUT_FILE}"

echo "Starting release notes generation (type: ${BUILD_TYPE})"

# ============================================================================
# Determine Commit Range
# ============================================================================

if [ "$BUILD_TYPE" = "daily" ]; then
    # Daily build: Get last successful workflow run
    START_REF=$(gh run list -w "build.yml" -b main -s success -L 1 \
        --json headSha -q '.[0].headSha // ""')

    if [ -z "$START_REF" ]; then
        # Fallback to first commit if no previous runs
        START_REF=$(git rev-list --max-parents=0 HEAD)
    fi

    END_REF="HEAD"

else
    # Release build: Get commits between last two tags
    TAGS=($(gh release list --limit 2 --json tagName -q '.[].tagName'))

    if [ ${#TAGS[@]} -ge 2 ]; then
        START_REF="${TAGS[1]}"
        END_REF="${TAGS[0]}"
    elif [ ${#TAGS[@]} -eq 1 ]; then
        # Only one tag, use from first commit to that tag
        START_REF=$(git rev-list --max-parents=0 HEAD)
        END_REF="${TAGS[0]}"
    else
        # No tags, use last 10 commits as fallback
        START_REF="HEAD~10"
        END_REF="HEAD"
    fi
fi

echo "Commit range: ${START_REF}..${END_REF}"

# ============================================================================
# Process Commits
# ============================================================================

stories="[]"
defects="[]"

# Get commits excluding merges
while IFS='|' read -r sha author message; do
    [ -z "$sha" ] && continue
    
    # Skip commits with [skip ci] in the message
    if echo "$message" | grep -iq "\[skip ci\]"; then
        echo "Skipping commit with [skip ci]: $sha"
        continue
    fi

    echo "Processing: $sha"

    # Get PR branch using GitHub CLI
    branch=$(gh api "repos/{owner}/{repo}/commits/$sha/pulls" \
        --jq '.[0].head.ref // "unknown"' 2>/dev/null || echo "unknown")
    # Create entry
    entry=$(jq -nc \
        --arg desc "$message" \
        --arg branch "$branch" \
        --arg author "$author" \
        '{description: $desc, branch: $branch, author: $author}')

    # Categorize: defect if message starts with "DEFECT" (case-insensitive)
    if echo "$message" | grep -iq "^defect"; then
        defects=$(echo "$defects" | jq -c --argjson e "$entry" '. + [$e]')
    else
        stories=$(echo "$stories" | jq -c --argjson e "$entry" '. + [$e]')
    fi

done < <(git log --no-merges --format="%H|%an|%s" ${START_REF}..${END_REF})

story_count=$(echo "$stories" | jq 'length')
defect_count=$(echo "$defects" | jq 'length')
echo "Categorized: ${story_count} stories, ${defect_count} defects"

# ============================================================================
# Update Release Notes
# ============================================================================

# Create new build entry
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
new_build=$(jq -nc \
    --arg ts "$timestamp" \
    --argjson stories "$stories" \
    --argjson defects "$defects" \
    '{timestamp: $ts, stories: $stories, defects: $defects}')

# Load existing or create new
mkdir -p "$(dirname "$OUTPUT_PATH")"

if [ -f "$OUTPUT_PATH" ]; then
    existing=$(cat "$OUTPUT_PATH")
else
    existing='{"builds": []}'
fi

# Append new build and keep last 50
updated=$(echo "$existing" | jq \
    --argjson build "$new_build" \
    '.builds += [$build] | .builds = .builds[-50:]')

# Save
echo "$updated" > "$OUTPUT_PATH"

echo "Release notes saved to ${OUTPUT_PATH}"
