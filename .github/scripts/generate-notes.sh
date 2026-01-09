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
    START_REF=$(gh run list -w "release-notes.yml" -b main -s success -L 1 \
        --json headSha -q '.[0].headSha // ""')

    if [ -z "$START_REF" ]; then
        # Fallback to first commit if no previous runs
        START_REF=$(git rev-list --max-parents=0 HEAD)
    fi

    END_REF="HEAD"

else
    # Release build: Commits from latest GitHub Release to current HEAD
    echo "Fetching latest GitHub Release..."

    # Get the latest release tag
    latest_tag=$(gh release list --limit 1 --json tagName -q '.[0].tagName // ""' 2>/dev/null || echo "")

    if [ -n "$latest_tag" ]; then
        # Commits from latest release to current HEAD on release branch
        START_REF="$latest_tag"
        END_REF="HEAD"
        echo "Latest release: $latest_tag"
        echo "Generating release notes from $latest_tag to current HEAD"
    else
        # No releases found, use first commit to HEAD
        START_REF=$(git rev-list --max-parents=0 HEAD)
        END_REF="HEAD"
        echo "No previous releases found, using entire history"
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

    # Get PR branch using GitHub API (direct endpoint for commit's PRs)
    branch=$(gh api "repos/{owner}/{repo}/commits/$sha/pulls" \
        --jq '.[0].head.ref // ""' 2>/dev/null || echo "")

    # If no PR found (direct commit), determine branch from git
    if [ -z "$branch" ]; then
        if git branch -r --contains "$sha" | grep -q "origin/main"; then
            branch="main"
        elif git branch -r --contains "$sha" | grep -q "origin/develop"; then
            branch="develop"
        else
            # Get first remote branch containing this commit
            branch=$(git branch -r --contains "$sha" | head -1 | sed 's/.*origin\///' | xargs)
            [ -z "$branch" ] && branch="unknown"
        fi
    fi

    # Create entry
    entry=$(jq -nc \
        --arg desc "$message" \
        --arg branch "$branch" \
        --arg author "$author" \
        '{description: $desc, branch: $branch, author: $author}')

    # Categorize: defect if message contains "DEFECT" (case-insensitive)
    # Convert to uppercase for comparison
    message_upper=$(echo "$message" | tr '[:lower:]' '[:upper:]')
    if [[ "$message_upper" =~ DEFECT ]]; then
        echo "  -> Categorized as DEFECT"
        defects=$(echo "$defects" | jq -c --argjson e "$entry" '. + [$e]')
    else
        echo "  -> Categorized as STORY"
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
revision=$(git rev-parse HEAD)
new_build=$(jq -nc \
    --arg ts "$timestamp" \
    --arg rev "$revision" \
    --argjson stories "$stories" \
    --argjson defects "$defects" \
    '{timestamp: $ts, revision: $rev, stories: $stories, defects: $defects}')

# Load existing or create new
mkdir -p "$(dirname "$OUTPUT_PATH")"

if [ "$BUILD_TYPE" = "daily" ]; then
    # Daily build: load from local file
    if [ -f "$OUTPUT_PATH" ]; then
        existing=$(cat "$OUTPUT_PATH")
    else
        existing='{"builds": []}'
    fi
else
    # Release build: download from latest GitHub Release assets
    echo "Downloading prod-release-notes.json from latest release..."

    if [ -n "$latest_tag" ]; then
        # Try to download the asset from the latest release
        if gh release download "$latest_tag" -p "prod-release-notes.json" -D "$(dirname "$OUTPUT_PATH")" 2>/dev/null; then
            echo "Downloaded existing prod-release-notes.json from $latest_tag"
            existing=$(cat "$OUTPUT_PATH")
        else
            echo "No prod-release-notes.json found in $latest_tag, creating new"
            existing='{"builds": []}'
        fi
    else
        echo "No previous release found, creating new prod-release-notes.json"
        existing='{"builds": []}'
    fi
fi

# Prepend new build and keep first 50 (most recent)
updated=$(echo "$existing" | jq \
    --argjson build "$new_build" \
    '.builds = [$build] + .builds | .builds = .builds[:50]')

# Save
echo "$updated" > "$OUTPUT_PATH"

echo "Release notes saved to ${OUTPUT_PATH}"
