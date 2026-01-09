#!/bin/bash
set -e # Exit on error

OUTPUT_PATH="release-notes/${OUTPUT_FILE}" # Path to output release notes file - 'release-notes/dev-release-notes.json' or 'release-notes/prod-release-notes.json'

echo "=== Starting release notes generation of type: ${BUILD_TYPE} ==="

# ============================================================================
# Determine Commit Range
# 1. For daily builds get commits from last successful workflow run to HEAD
# 2. For release builds get commits between last two tags
# ============================================================================
echo "=== Determining commit range ==="
if [ "$BUILD_TYPE" = "daily" ]; then
    echo "=== Daily build: Getting last successful workflow run ==="
    START_REF=$(gh run list -w "build.yml" -b main -s success -L 1 \
        --json headSha -q '.[0].headSha // ""')

    if [ -z "$START_REF" ]; then
        echo "=== Daily build: Falling back to first commit as there are no previous successful runs ==="
        START_REF=$(git rev-list --max-parents=0 HEAD)
    fi
    END_REF="HEAD"

else
    echo "=== Release build: Getting commits between last two tags ==="
    TAGS=($(gh release list --limit 2 --json tagName -q '.[].tagName'))

    if [ ${#TAGS[@]} -ge 2 ]; then
        START_REF="${TAGS[1]}"
        END_REF="${TAGS[0]}"
    elif [ ${#TAGS[@]} -eq 1 ]; then
        echo "=== Release build: Only one tag found, using commits from first commit to that tag ==="
        START_REF=$(git rev-list --max-parents=0 HEAD)
        END_REF="${TAGS[0]}"
    else
        echo "=== Release build: No tags found, using last 10 commits as fallback ==="
        START_REF="HEAD~10"
        END_REF="HEAD"
    fi
fi
echo "Commit range: ${START_REF}..${END_REF}"
echo "=== Completed determining commit range ==="


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
    # Skip commits with [skip ci] in the message
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
# 2. Append to existing release notes file, keeping only last 50 builds
# 3. Save updated release notes back to file
# ============================================================================

echo "=== Updating release notes file with new build entry: ${OUTPUT_PATH} ==="

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
revision=$(git rev-parse HEAD)
new_build=$(jq -nc \
    --arg ts "$timestamp" \
    --arg rev "$revision" \
    --argjson stories "$stories" \
    --argjson defects "$defects" \
    '{timestamp: $ts, revision: $rev, stories: $stories, defects: $defects}')

echo "=== Creating directory for release notes if it doesn't exist ==="
mkdir -p "$(dirname "$OUTPUT_PATH")"

if [ -f "$OUTPUT_PATH" ]; then
    existing=$(cat "$OUTPUT_PATH")
else
    existing='{"builds": []}'
fi

echo "=== Appending new build and keeping last 50 ==="
updated=$(echo "$existing" | jq \
    --argjson build "$new_build" \
    '.builds = [$build] + .builds | .builds = .builds[:50]')

echo "$updated" > "$OUTPUT_PATH"

echo "=== Release notes saved to ${OUTPUT_PATH} ==="
