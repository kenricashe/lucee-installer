#!/bin/bash

# Usage:
# curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/master/lucee/linux/sys/upgrade-in-progress/install.sh | sudo bash
#
# Example with custom Lucee root path in environment variable:
# curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/master/lucee/linux/sys/upgrade-in-progress/install.sh | sudo env LUCEE_ROOT=/opt/lucee6 bash
#
# Example with non-master branch name in URL e.g. for QA testing:
# (URL="https://raw.githubusercontent.com/kenricashe/lucee-installer/feature/upgrade-in-progress-apache/lucee/linux/sys/upgrade-in-progress/install.sh"; curl -fsSL "$URL" | sudo env SOURCE_URL="$URL" bash)
#
# GitHub CDN caching can last 5 minutes. For quicker testing, in the URL replace branch with the commit sha:
# (URL="https://raw.githubusercontent.com/kenricashe/lucee-installer/<commit-sha>/lucee/linux/sys/upgrade-in-progress/install.sh"; curl -fsSL "$URL" | sudo env SOURCE_URL="$URL" bash)

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

# UPDATE THIS WITH EACH COMMIT
echo ""
echo "install.sh version: 2025-08-24 16:26:40 Pacific"

OWNER=${OWNER:-kenricashe}
REPO=${REPO:-lucee-installer}

# Optional: allow the invoking environment to pass the exact installer URL
# This is useful for pipelines where the curl process isn't visible to this shell
if [ -n "$SOURCE_URL" ] && [[ "$SOURCE_URL" == *"/raw.githubusercontent.com/"* ]]; then
	SRC_OWNER=$(printf '%s\n' "$SOURCE_URL" | sed -n 's|.*/raw.githubusercontent.com/\([^/]*\)/[^/]*/.*|\1|p')
	SRC_REPO=$(printf '%s\n' "$SOURCE_URL" | sed -n 's|.*/raw.githubusercontent.com/[^/]*/\([^/]*\)/.*|\1|p')
	# Try to capture refs that contain slashes by matching the known suffix path
	SRC_REF=$(printf '%s\n' "$SOURCE_URL" | sed -n 's|.*/raw.githubusercontent.com/[^/]*/[^/]*/\(.*\)/lucee/linux/sys/upgrade-in-progress/install.sh|\1|p')
	# Fallback to single-segment capture if the precise match fails
	if [ -z "$SRC_REF" ]; then
		SRC_REF=$(printf '%s\n' "$SOURCE_URL" | sed -n 's|.*/raw.githubusercontent.com/[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
	fi
	if [ -n "$SRC_OWNER" ] && [ "$OWNER" = "kenricashe" ]; then
		OWNER="$SRC_OWNER"
	fi
	if [ -n "$SRC_REPO" ] && [ "$REPO" = "lucee-installer" ]; then
		REPO="$SRC_REPO"
	fi
	if [ -n "$SRC_REF" ] && [ -z "$REF" ]; then
		REF="$SRC_REF"
	fi
fi

# Auto-derive REF from the invoking raw.githubusercontent.com URL (curl | bash) when not provided
if [ -z "$REF" ]; then
	URL_REF_AUTO=""
	for PID in "$PPID" "$$"; do
		if [ -r "/proc/$PID/cmdline" ]; then
			CMDLINE=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null)
			if [[ "$CMDLINE" == *"/raw.githubusercontent.com/"* ]]; then
				# Prefer precise capture using known suffix to support refs with slashes
				URL_REF_AUTO=$(printf '%s\n' "$CMDLINE" | sed -n 's|.*raw.githubusercontent.com/[^/]*/[^/]*/\(.*\)/lucee/linux/sys/upgrade-in-progress/install.sh|\1|p')
				if [ -z "$URL_REF_AUTO" ]; then
					URL_REF_AUTO=$(printf '%s\n' "$CMDLINE" | sed -n 's|.*raw.githubusercontent.com/[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
				fi
				if [ -n "$URL_REF_AUTO" ]; then
					break
				fi
			fi
		fi
	done

	# Fallback: search across all processes (useful for curl | sudo bash pipelines)
	if [ -z "$URL_REF_AUTO" ]; then
		for PROC in /proc/[0-9]*/cmdline; do
			if [ -r "$PROC" ]; then
				CMDLINE=$(tr '\0' ' ' < "$PROC" 2>/dev/null)
				if [[ "$CMDLINE" == *"/raw.githubusercontent.com/"* ]] && [[ "$CMDLINE" == *"/lucee/linux/sys/upgrade-in-progress/install.sh"* ]]; then
					# Prefer precise capture using known suffix to support refs with slashes
					URL_REF_AUTO=$(printf '%s\n' "$CMDLINE" | sed -n 's|.*raw.githubusercontent.com/[^/]*/[^/]*/\(.*\)/lucee/linux/sys/upgrade-in-progress/install.sh|\1|p')
					if [ -z "$URL_REF_AUTO" ]; then
						URL_REF_AUTO=$(printf '%s\n' "$CMDLINE" | sed -n 's|.*raw.githubusercontent.com/[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
					fi
					if [ -n "$URL_REF_AUTO" ]; then
						break
					fi
				fi
			fi
		done
	fi
	if [ -n "$URL_REF_AUTO" ]; then
		REF="$URL_REF_AUTO"
		echo "Auto-detected REF=$REF from installer URL"
	fi
fi
REF=${REF:-master}

TARBALL_URL="https://codeload.github.com/${OWNER}/${REPO}/tar.gz/${REF}"
TMPDIR=$(mktemp -d)

cleanup() {
	if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
		rm -rf "$TMPDIR"
	fi
}
trap cleanup EXIT

echo ""
echo "Downloading ${OWNER}/${REPO}@${REF} ..."

# When extracting GitHub tarballs, the top directory will be named {repo}-{ref}
# where {ref} has '/' characters replaced with '-'
if ! curl -fsSL "$TARBALL_URL" | tar -xz -C "$TMPDIR"; then
	echo ""
	echo "Error: Failed to download or extract tarball: $TARBALL_URL"
	exit 1
fi

# Find the subdirectory containing this toolset
# GitHub tarballs include a top-level directory named {repo}-{ref}
# where branch refs with slashes are converted to hyphens
echo ""
echo "Searching for upgrade-in-progress directory..."

# First, find the top-level directory (should be something like lucee-installer-feature-upgrade-in-progress-apache)
TOP_DIR=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n1)
echo ""
echo "Found top-level directory: $TOP_DIR"

# Now look for the upgrade-in-progress directory within that top-level directory
SUBDIR="$TOP_DIR/lucee/linux/sys/upgrade-in-progress"

if [ ! -d "$SUBDIR" ]; then
	# If direct path doesn't work, try a more general search
	SUBDIR=$(find "$TMPDIR" -type d -path "*/lucee/linux/sys/upgrade-in-progress" | head -n1)

	if [ -z "$SUBDIR" ]; then
		# Debug: Show the directory structure to help diagnose the issue
		echo ""
		echo "Directory structure in tarball:"
		find "$TMPDIR" -type d | sort
		echo ""
		echo "Error: Could not locate subdirectory lucee/linux/sys/upgrade-in-progress in the tarball"
		exit 1
	fi
fi

echo ""
echo "Found upgrade-in-progress directory at: $SUBDIR"

# Run the deployment script from the extracted directory
if [ ! -x "$SUBDIR/deploy-to-opt-lucee-sys.sh" ]; then
	chmod +x "$SUBDIR/deploy-to-opt-lucee-sys.sh" 2>/dev/null || true
fi

# Check for Lucee root path from environment variable first
DEFAULT_LUCEE_ROOT="/opt/lucee"

if [ -n "$LUCEE_ROOT" ]; then
	# Environment variable provided
	: # do nothing
elif [ -t 0 ]; then
	# Interactive mode - prompt for Lucee root path
	echo ""
	read -r -p "Enter target Lucee root path [${DEFAULT_LUCEE_ROOT}]: " INPUT_LUCEE_ROOT
	LUCEE_ROOT="${INPUT_LUCEE_ROOT:-$DEFAULT_LUCEE_ROOT}"
else
	# Non-interactive mode (curl pipe) - use default and continue
	LUCEE_ROOT="$DEFAULT_LUCEE_ROOT"
fi

# Execute the deployment script and capture its exit status
if "$SUBDIR/deploy-to-opt-lucee-sys.sh" "$LUCEE_ROOT"; then
	# Deployment was successful
	echo ""
	echo "=================================================================="
	echo ""
	echo "Installation complete!"
	echo ""
	echo "To configure and manage 'Upgrade in Progress' toggling, run:"
	echo ""
	echo "sudo ${LUCEE_ROOT}/sys/upgrade-in-progress/menu.sh"
	echo ""
	echo "=================================================================="
else
	# Deployment failed
	DEPLOY_STATUS=$?
	echo ""
	echo "=================================================================="
	echo "ERROR: Deployment failed with exit code $DEPLOY_STATUS"
	echo "Please check the error messages above for more information."
	echo "=================================================================="
	exit $DEPLOY_STATUS
fi
