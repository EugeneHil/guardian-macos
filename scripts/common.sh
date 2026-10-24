#!/usr/bin/env bash
# Sourced by the other scripts. Runs tuist from PATH, or through mise when it is not activated.
run_tuist() {
  if command -v tuist >/dev/null 2>&1; then
    command tuist "$@"
  else
    mise exec -- tuist "$@"
  fi
}
