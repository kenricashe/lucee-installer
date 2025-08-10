#!/bin/bash

# Shared environment for upgrade-in-progress scripts
# Sets LUCEE_ROOT, UPG_DIR (relative to this file), and IS_CPANEL.

# Determine library directory, resolving symlinks where available
LIB_PATH="${BASH_SOURCE[0]:-$0}"
if command -v readlink >/dev/null 2>&1; then
	# Prefer fully resolved path for robustness
	RESOLVED="$(readlink -f "$LIB_PATH" 2>/dev/null)"
	if [ -n "$RESOLVED" ]; then
		LIB_PATH="$RESOLVED"
	fi
fi
LIB_DIR="$(cd -P "$(dirname "$LIB_PATH")" && pwd)"

# Lucee root is two directories up from upgrade-in-progress
LUCEE_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
LUCEE_ROOT="${LUCEE_ROOT%/}"
UPG_DIR="${LUCEE_ROOT}/sys/upgrade-in-progress"

# Detect cPanel (available to callers)
if [ -f "/usr/local/cpanel/cpanel" ]; then
	IS_CPANEL=true
else
	IS_CPANEL=false
fi
