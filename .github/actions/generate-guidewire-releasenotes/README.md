# Generate Guidewire Release Notes Action

A composite GitHub Action that automatically generates release notes JSON files for Guidewire applications based on git commits and categorizes them into stories and defects.

## Table of Contents
- [Overview](#overview)
- [Inputs](#inputs)
- [Usage](#usage)
- [Workflow Logic](#workflow-logic)
- [Script Details](#script-details)
  - [generate-trunk-build-notes.sh](#generate-trunk-build-notessh)
  - [generate-release-build-notes.sh](#generate-release-build-notessh)
- [JSON Structure](#json-structure)
- [Dependencies](#dependencies)
- [Edge Cases](#edge-cases)
- [Troubleshooting](#troubleshooting)

## Overview

This composite action provides automated release notes generation for two distinct scenarios:

1. **Trunk/Daily Builds** - Generates development release notes from commits since the last successful workflow run
2. **Release Builds** - Generates production release notes from commits since the last GitHub release

The action processes git commits, determines their source branches, categorizes them as stories or defects, and maintains historical release notes in JSON format.

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `RELEASE_VERSION` | The semantic version to use as revision for release builds (e.g., "5.0.6") | No | - |
| `ASSET_PACKAGE_NAME` | Name of the package(.zip) which has the release notes (e.g., app-package.json)| No | - |
| `OUTPUT_FILE` | The output file path for trunk release notes (relative to repo root) | No | - |
| `GIT_TOKEN` | GitHub token for API authentication | **Yes** | - |

## Usage

### Basic Usage

```yaml
- name: Generate Release Notes for releases
  uses: ./.github/actions/generate-guidewire-releasenotes
  with:
    GIT_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    OUTPUT_FILE: 'release-notes/dev-release-notes.json'
    RELEASE_VERSION: '5.0.6'
    ASSET_PACKAGE_NAME: 'app-package.zip'
```

## Workflow Logic

The action uses branch-based conditional logic:

1. **Main Branch** (`startsWith(github.ref_name, 'main')`)
   - Executes `generate-trunk-build-notes.sh`
   - Commits and pushes changes back to the repository
   - Uses git commit hashes as revisions

2. **Release Branch** (`startsWith(github.ref_name, 'release/')`)
   - Executes `generate-release-build-notes.sh`
   - Downloads existing release notes from latest GitHub release
   - Uses semantic version from `RELEASE_VERSION` as revision

## Script Details

### generate-trunk-build-notes.sh

**Purpose**: Generates daily/trunk build release notes for continuous integration workflows.

#### Tools Used
- **GitHub CLI (`gh`)**: API interactions, workflow run queries
- **jq**: JSON processing and manipulation
- **git**: Commit history analysis and repository operations
- **bash**: Shell scripting with process substitution

#### Logic Flow

1. **Commit Range Determination**
   ```bash
   START_REF=$(gh run list -w "build.yml" -b main -s success -L 1 --json headSha -q '.[0].headSha // ""')
   ```
   - Queries the last successful workflow run on main branch
   - Falls back to repository's first commit if no previous runs exist
   - Sets range from last successful run to current HEAD

2. **Commit Processing**
   - Iterates through commits using `git log --no-merges --format="%H|%an|%s"`
   - Skips commits containing `[skip ci]` marker
   - Processes each commit for branch detection and categorization

3. **Branch Detection Algorithm**
   - **Primary Method**: GitHub API to find associated Pull Request
     ```bash
     branch=$(gh api "repos/{owner}/{repo}/commits/$sha/pulls" --jq '.[0].head.ref // ""')
     ```
   - **Fallback Method**: Git remote branch analysis
     - Checks `origin/main` and `origin/develop` first
     - Falls back to first remote branch containing the commit
     - Defaults to "unknown" if no branch found

4. **Commit Categorization**
   - **Defects**: Commits with "DEFECT" keyword (case-insensitive)
   - **Stories**: All other commits
   - Creates structured JSON entries with description, branch, and author

5. **File Operations**
   - Creates output directory if needed
   - Loads existing release notes or initializes empty structure
   - Appends new build entry and maintains last 50 builds
   - Uses git commit hash as revision identifier

#### Edge Cases Handled

- **No Previous Workflow Runs**: Falls back to repository's initial commit
- **Direct Commits**: Uses git branch analysis when no PR association exists
- **Empty Commit Messages**: Filters out empty SHA values
- **File Not Exists**: Creates new JSON structure with empty builds array
- **Skip CI Commits**: Automatically excludes commits marked with `[skip ci]`

#### Error Handling
- Suppresses GitHub API errors with `2>/dev/null`
- Uses null coalescing in jq queries (`// ""`)
- Validates commit SHA existence before processing

---

### generate-release-build-notes.sh

**Purpose**: Generates production release notes for formal software releases.

#### Tools Used
- **GitHub CLI (`gh`)**: Release management, file downloads, API queries
- **jq**: JSON processing and build entry creation
- **git**: Commit range analysis and revision parsing
- **bash**: Advanced shell scripting with error handling

#### Logic Flow

1. **Release Detection**
   ```bash
   latest_tag=$(gh release view --json tagName -q '.tagName // ""')
   ```
   - Queries the most recent GitHub release
   - Uses entire repository history if no previous releases exist
   - Sets commit range from latest release tag to current HEAD

2. **Commit Processing** (Similar to trunk script)
   - Same branch detection and categorization logic
   - Identical filtering for `[skip ci]` commits
   - Uses consistent JSON structure for commit entries

3. **Build Entry Creation**
   - Uses `RELEASE_VERSION` environment variable as revision
   - Creates timestamp in ISO 8601 UTC format
   - Structures build with stories and defects arrays

4. **Release Notes Integration**
   ```bash
   gh release download -p "prod-release-notes.json"
   ```
   - Downloads existing `prod-release-notes.json` from latest release
   - Falls back to empty structure if file doesn't exist
   - Maintains consistency with previous release history

5. **File Management**
   - Prepends new build entry to existing builds array
   - Limits to last 50 builds for performance
   - Outputs final JSON to `prod-release-notes.json`

#### Key Differences from Trunk Script

| Aspect | Trunk Script | Release Script |
|--------|--------------|----------------|
| **Revision** | Git commit hash | Semantic version from `RELEASE_VERSION` |
| **Commit Range** | Last workflow run → HEAD | Last release tag → HEAD |
| **File Source** | Local filesystem | Downloaded from GitHub release |
| **Output File** | `$OUTPUT_FILE` variable | Fixed `prod-release-notes.json` |
| **Persistence** | Committed to repository | Prepared for release artifact |

#### Edge Cases Handled

- **First Release**: Creates new JSON structure when no previous releases exist
- **Missing Release File**: Gracefully handles absence of `prod-release-notes.json` in releases
- **Download Failures**: Falls back to empty structure if download fails
- **Version Format**: Accepts any string format for `RELEASE_VERSION`

#### Error Handling
- Comprehensive error suppression for GitHub operations
- Null-safe JSON processing with jq
- Graceful degradation when GitHub API is unavailable

## JSON Structure

Both scripts generate consistent JSON structure:

```json
{
  "builds": [
    {
      "timestamp": "2026-01-09T18:30:45Z",
      "revision": "abc123def" | "5.0.6",
      "stories": [
        {
          "description": "Add new feature for user management",
          "branch": "feature/user-mgmt",
          "author": "John Doe"
        }
      ],
      "defects": [
        {
          "description": "Fix DEFECT-123: Login validation error",
          "branch": "bugfix/login-fix", 
          "author": "Jane Smith"
        }
      ]
    }
  ]
}
```

### Field Descriptions

- **timestamp**: ISO 8601 UTC timestamp of build generation
- **revision**: Unique identifier (git hash for trunk, version for releases)
- **stories**: Array of feature commits and general improvements
- **defects**: Array of bug fixes and defect corrections
- **description**: Full commit message
- **branch**: Source branch of the commit (detected via PR or git analysis)
- **author**: Git commit author name

## Dependencies

### Required Tools
- **GitHub CLI**: Version 2.0+ with authentication
- **jq**: JSON processor for data manipulation
- **git**: Version control system (typically pre-installed in runners)
- **bash**: Shell interpreter with process substitution support

### Required Permissions
- **Repository**: Read access for git operations
- **Actions**: Read access for workflow run queries
- **Releases**: Read access for release downloads
- **Contents**: Write access for committing trunk build changes

## Troubleshooting

### Common Issues

1. **"No previous workflow runs found"**
   - Expected behavior for first run
   - Script will process entire repository history

2. **"Permission denied" errors**
   - Verify `GIT_TOKEN` has sufficient permissions
   - Check repository settings for Actions permissions

3. **"jq: command not found"**
   - GitHub Actions runners include jq by default
   - For local testing, install jq package

4. **Empty release notes generated**
   - Check if commits exist in the specified range
   - Verify commits don't all contain `[skip ci]`

5. **Branch detection shows "unknown"**
   - Indicates commit not found in common branches
   - May occur with direct pushes or complex merge scenarios


### Local Testing

```bash
# Set required environment variables
export GH_TOKEN="your-github-token"
export OUTPUT_FILE="release-notes/test.json"
export RELEASE_VERSION="1.0.0"

# Run scripts directly
bash scripts/generate-trunk-build-notes.sh
bash scripts/generate-release-build-notes.sh
```