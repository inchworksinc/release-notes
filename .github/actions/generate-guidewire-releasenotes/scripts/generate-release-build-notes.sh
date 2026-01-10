#!/bin/bash
set -e

echo "=== Starting release build release notes generation ==="

# ============================================================================
# Determining Commit Range for Release Builds
# 1. Get commits from latest GitHub Release tag to HEAD
# 2. If no previous release, get all commits
# ============================================================================
echo "=== Determining commit range ==="
latest_tag=$(gh release view --json tagName -q '.tagName // ""' 2>/dev/null || echo "")
if [ -n "$latest_tag" ]; then
    echo "=== Generating release notes from $latest_tag to current HEAD ==="
    START_REF="$latest_tag"
    END_REF="HEAD"
else
    echo "=== No previous releases found, using entire history ==="
    START_REF=$(git rev-list --max-parents=0 HEAD)
    END_REF="HEAD"
fi

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

    echo "=== Skipping commits with [skip ci] in the message ==="
    if echo "$message" | grep -iq "\[skip ci\]"; then
        echo "Skipping commit with [skip ci]: $sha"
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
# Updating Release Notes
# 1. Create new build entry with timestamp, revision, stories, defects
# 2. Download existing prod-release-notes.json from latest release
# 3. Append to existing release notes file, keeping only last 50 builds
# 4. Save updated release notes back to file
# ============================================================================

# Create new build entry
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
revision=$RELEASE_VERSION
new_build=$(jq -nc \
    --arg ts "$timestamp" \
    --arg rev "$revision" \
    --argjson stories "$stories" \
    --argjson defects "$defects" \
    '{timestamp: $ts, revision: $rev, stories: $stories, defects: $defects}')

echo "=== Downloading prod-release-notes.json from latest release ==="
if [ -n "$latest_tag" ]; then
    if gh release download -p "prod-release-notes.json" 2>/dev/null; then
        echo "=== Downloaded existing prod-release-notes.json from $latest_tag ==="
        existing=$(cat prod-release-notes.json)
    else
        echo "=== No prod-release-notes.json found in latest release, creating new ==="
        existing='{"builds": []}'
    fi
else
    echo "=== No previous release found, creating new prod-release-notes.json ==="
    existing='{"builds": []}'
fi

echo "=== Appending new build and keeping last release builds ==="
updated=$(echo "$existing" | jq \
    --argjson build "$new_build" \
    '.builds = [$build] + .builds | .builds = .builds[:50]')

# Save
echo "$updated" > prod-release-notes.json

echo "=== Release notes file prod-release-notes.json updated ==="

cat prod-release-notes.json