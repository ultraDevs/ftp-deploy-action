#!/usr/bin/env bash
# Core logic for the lftp FTP/FTPS Deploy action. Invoked by action.yml with
# all configuration passed via environment variables (see action.yml for the
# full list). Not meant to be run standalone outside the action context.

set -euo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
LOCAL_DIR_ABS="$(cd "$WORKSPACE/${LOCAL_DIR:-.}" && pwd)"

: "${FTP_SERVER:?server input is required}"
: "${FTP_USERNAME:?username input is required}"
: "${FTP_PASSWORD:?password input is required}"
: "${REMOTE_DIR:?remote-dir input is required}"
FTP_PORT="${FTP_PORT:-21}"
FTP_PROTOCOL="${FTP_PROTOCOL:-ftps}"
FTP_SSL_VERIFY="${FTP_SSL_VERIFY:-true}"
FULL_DEPLOY="${FULL_DEPLOY:-false}"
DRY_RUN="${DRY_RUN:-false}"

[[ "$REMOTE_DIR" != */ ]] && REMOTE_DIR="$REMOTE_DIR/"

# Parse the newline-separated exclude input into dir / file / glob buckets
# so both the full-mirror rsync staging step and the incremental per-file
# filter apply the exact same rules.
EXCLUDE_DIRS=()
EXCLUDE_FILES=()
EXCLUDE_GLOBS=()
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  if [[ "$entry" == *"*"* ]]; then
    EXCLUDE_GLOBS+=("$entry")
  elif [[ "$entry" == */* ]]; then
    EXCLUDE_FILES+=("$entry")
  else
    EXCLUDE_DIRS+=("$entry")
    EXCLUDE_FILES+=("$entry")
  fi
done <<< "${EXCLUDE_LIST:-}"

is_excluded() {
  local path="$1" top="${1%%/*}" base="${1##*/}"
  local _d _f _g
  for _d in "${EXCLUDE_DIRS[@]:-}"; do [ -n "$_d" ] && [ "$top" = "$_d" ] && return 0; done
  for _f in "${EXCLUDE_FILES[@]:-}"; do [ -n "$_f" ] && { [ "$path" = "$_f" ] || [ "$base" = "$_f" ]; } && return 0; done
  for _g in "${EXCLUDE_GLOBS[@]:-}"; do [ -n "$_g" ] && [[ "$base" == $_g ]] && return 0; done
  return 1
}

if ! command -v lftp >/dev/null 2>&1; then
  echo "::error::lftp is not installed — the action's 'Install lftp' step should have handled this." >&2
  exit 1
fi

LFTP_SETTINGS="set xfer:log yes; set net:timeout 15; set net:max-retries 2;"
if [ "$FTP_PROTOCOL" = "ftps" ]; then
  LFTP_SETTINGS="$LFTP_SETTINGS set ftp:ssl-force true; set ftp:ssl-protect-data true;"
fi
if [ "$FTP_SSL_VERIFY" = "false" ]; then
  LFTP_SETTINGS="$LFTP_SETTINGS set ssl:verify-certificate no;"
fi

run_lftp() {
  if [ "$DRY_RUN" = "true" ]; then
    echo "--- dry-run: lftp commands that would run ---"
    echo "$1"
    return 0
  fi
  lftp -u "$FTP_USERNAME,$FTP_PASSWORD" -p "$FTP_PORT" "$FTP_SERVER" <<EOF
$1
EOF
}

full_deploy() {
  echo "Mode: full mirror"
  echo "mode=full" >> "$GITHUB_OUTPUT"

  RSYNC_EXCLUDES=()
  local _e
  for _e in "${EXCLUDE_DIRS[@]:-}" "${EXCLUDE_FILES[@]:-}" "${EXCLUDE_GLOBS[@]:-}"; do
    [ -n "$_e" ] && RSYNC_EXCLUDES+=(--exclude "$_e")
  done

  STAGE_DIR="$(mktemp -d)"
  trap 'rm -rf "$STAGE_DIR"' EXIT
  rsync -a "$LOCAL_DIR_ABS"/ "$STAGE_DIR"/ "${RSYNC_EXCLUDES[@]}"

  MIRROR_CMD="mirror --reverse --delete --verbose"
  [ "$DRY_RUN" = "true" ] && MIRROR_CMD="$MIRROR_CMD --dry-run"

  echo "Connecting to $FTP_SERVER:$FTP_PORT ($FTP_PROTOCOL), uploading to $REMOTE_DIR"
  run_lftp "$LFTP_SETTINGS
$MIRROR_CMD \"$STAGE_DIR/\" \"$REMOTE_DIR\"
bye"
}

incremental_deploy() {
  echo "Mode: incremental ($GIT_BEFORE_SHA -> $GIT_HEAD_SHA)"
  echo "mode=incremental" >> "$GITHUB_OUTPUT"

  CHANGED=$(git -C "$LOCAL_DIR_ABS" diff --name-only --diff-filter=ACMRT "$GIT_BEFORE_SHA" "$GIT_HEAD_SHA")
  DELETED=$(git -C "$LOCAL_DIR_ABS" diff --name-only --diff-filter=D "$GIT_BEFORE_SHA" "$GIT_HEAD_SHA")

  LFTP_CMDS="$LFTP_SETTINGS"
  UPLOAD_COUNT=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    is_excluded "$f" && continue
    [ -f "$LOCAL_DIR_ABS/$f" ] || continue
    remote_path="$REMOTE_DIR$f"
    remote_dir="${remote_path%/*}"
    LFTP_CMDS="$LFTP_CMDS
mkdir -p -f \"$remote_dir\"
put \"$LOCAL_DIR_ABS/$f\" -o \"$remote_path\""
    UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
  done <<< "$CHANGED"

  DELETE_COUNT=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    is_excluded "$f" && continue
    remote_path="$REMOTE_DIR$f"
    LFTP_CMDS="$LFTP_CMDS
rm -f \"$remote_path\""
    DELETE_COUNT=$((DELETE_COUNT + 1))
  done <<< "$DELETED"

  echo "uploaded-count=$UPLOAD_COUNT" >> "$GITHUB_OUTPUT"
  echo "deleted-count=$DELETE_COUNT" >> "$GITHUB_OUTPUT"

  if [ "$UPLOAD_COUNT" -eq 0 ] && [ "$DELETE_COUNT" -eq 0 ]; then
    echo "No deployable file changes between $GIT_BEFORE_SHA and $GIT_HEAD_SHA."
    return 0
  fi

  echo "Uploading $UPLOAD_COUNT changed file(s), removing $DELETE_COUNT deleted file(s)."
  echo "Connecting to $FTP_SERVER:$FTP_PORT ($FTP_PROTOCOL)"
  run_lftp "$LFTP_CMDS
bye"
}

can_run_incremental() {
  [ "$FULL_DEPLOY" = "true" ] && { echo "full-deploy input is true"; return 1; }
  [ "${GITHUB_EVENT_NAME:-}" != "push" ] && { echo "event is '$GITHUB_EVENT_NAME', not 'push'"; return 1; }
  [ -z "${GIT_BEFORE_SHA:-}" ] && { echo "no before-SHA available"; return 1; }
  [[ "$GIT_BEFORE_SHA" =~ ^0+$ ]] && { echo "before-SHA is all-zeros (new branch)"; return 1; }
  git -C "$LOCAL_DIR_ABS" cat-file -e "$GIT_BEFORE_SHA" 2>/dev/null || {
    echo "before-SHA $GIT_BEFORE_SHA not present locally — checkout needs fetch-depth: 0 (or a large enough depth) for incremental deploys"
    return 1
  }
  return 0
}

REASON="$(can_run_incremental)" && USE_INCREMENTAL=true || USE_INCREMENTAL=false

if $USE_INCREMENTAL; then
  incremental_deploy
else
  [ -n "$REASON" ] && echo "Falling back to full mirror: $REASON"
  full_deploy
fi

echo "Done."
