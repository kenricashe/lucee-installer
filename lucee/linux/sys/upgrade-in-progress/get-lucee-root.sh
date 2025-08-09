#!/bin/bash

# Print the Lucee root path derived from this file's location.
# Assumes this file resides in: LUCEE_ROOT/sys/upgrade-in-progress/get-lucee-root.sh

# Resolve the path of this script (works when executed or sourced, handles symlinks)
SOURCE="${BASH_SOURCE[0]:-$0}"
if command -v readlink >/dev/null 2>&1; then
	# Resolve any symlinks to get the real path
	while [ -L "$SOURCE" ]; do
		DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
		LINK="$(readlink "$SOURCE")"
		[[ "$LINK" != /* ]] && SOURCE="$DIR/$LINK" || SOURCE="$LINK"
	done
fi
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# Lucee root is two directories up from upgrade-in-progress
LUCEE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LUCEE_ROOT="${LUCEE_ROOT%/}"

printf "%s\n" "$LUCEE_ROOT"
