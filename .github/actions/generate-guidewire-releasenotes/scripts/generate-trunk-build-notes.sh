#!/bin/bash
set -e

echo "=== Starting daily build release notes generation ==="

# ============================================================================
# Determining Commit Range for Daily Builds
# 1. Get commits from last successful workflow run to HEAD
# 2. If no previous successful run, get all commits
# ============================================================================
echo "=== Determining commit range ==="
echo "=== Daily build: Getting last successful workflow run ==="
START_REF=$(gh run list -w "build.yml" -b main -s success -L 1 \
    --json headSha -q '.[0].headSha // ""')

if [ -z "$START_REF" ]; then
    echo "=== Daily build: Falling back to first commit as there are no previous successful runs ==="
    START_REF=$(git rev-list --max-parents=0 HEAD)
fi

END_REF="HEAD"

echo "Commit range: ${START_REF}..${END_REF}"

# ============================================================================
# Process Commits
# 1. Determine the branch for each commit
# 2. Categorize commits into stories and defects
# ============================================================================

stories="[]"
defects="[]"

# Get commits excluding merges
while IFS='|' read -r sha author message; do
    [ -z "$sha" ] && continue
    if echo "$message" | grep -iq "\[skip ci\]"; then
        echo "=== Skipping commit with [skip ci]: $sha ==="
        continue
    fi

    # ============================
    # Getting branch of the commit
    # ============================
    echo "=== Processing: $sha. Getting branch of the commit ==="
    branch=$(gh api "repos/{owner}/{repo}/commits/$sha/pulls" \
        --jq '.[0].head.ref // ""' 2>/dev/null || echo "")

    # If no PR found (direct commit), determine branch from git
    if [ -z "$branch" ]; then
        echo "=== PR branch not found, checking remote branches ==="
        if git branch -r --contains "$sha" | grep -q "origin/main"; then
            branch="main"
        elif git branch -r --contains "$sha" | grep -q "origin/develop"; then
            branch="develop"
        else
            echo "=== $sha not found in origin/main or origin/develop, checking other remote branches ==="
            branch=$(git branch -r --contains "$sha" | head -1 | sed 's/.*origin\///' | xargs)
            [ -z "$branch" ] && branch="unknown"
        fi
    fi

    echo "=== $sha is in branch: $branch ==="

    # ============================
    # Categorizing the commit
    # ============================
    echo "=== Creating a commit entry ==="
    entry=$(jq -nc \
        --arg desc "$message" \
        --arg branch "$branch" \
        --arg author "$author" \
        '{description: $desc, branch: $branch, author: $author}')

    # Categorize: defect if message contains "DEFECT" (case-insensitive)
    # Convert to uppercase for comparison
    message_upper=$(echo "$message" | tr '[:lower:]' '[:upper:]')
    if [[ "$message_upper" =~ DEFECT ]]; then
        echo "=== Defect commit found ==="
        defects=$(echo "$defects" | jq -c --argjson e "$entry" '. + [$e]')
    else
        echo "=== Non defect commit found ==="
        stories=$(echo "$stories" | jq -c --argjson e "$entry" '. + [$e]')
    fi

done < <(git log --no-merges --format="%H|%an|%s" ${START_REF}..${END_REF}) # Read commits in range, excluding merges

story_count=$(echo "$stories" | jq 'length')
defect_count=$(echo "$defects" | jq 'length')
echo "=== Categorized: ${story_count} stories, ${defect_count} defects ==="

# ============================================================================
# Updating Daily Release Notes
# 1. Create new build entry with timestamp, revision, stories, defects
# 2. Append to existing release notes file, keeping only last 50 builds
# 3. Save updated release notes back to file
# ============================================================================

# Create new build entry
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
revision=$(git rev-parse HEAD)
new_build=$(jq -nc \
    --arg ts "$timestamp" \
    --arg rev "$revision" \
    --argjson stories "$stories" \
    --argjson defects "$defects" \
    '{timestamp: $ts, revision: $rev, stories: $stories, defects: $defects}')

echo "=== Creating empty release notes if it doesn't exist ==="
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Load existing daily release notes or create new
if [ -f "$OUTPUT_FILE" ]; then
    existing=$(cat "$OUTPUT_FILE")
else
    existing='{"builds": []}'
fi

echo "=== Appending new build and keeping last 50 ==="
updated=$(echo "$existing" | jq \
    --argjson build "$new_build" \
    '.builds = [$build] + .builds | .builds = .builds[:50]')

# Save
echo "$updated" > "$OUTPUT_FILE"

echo "=== Daily release notes saved to ${OUTPUT_FILE} ==="