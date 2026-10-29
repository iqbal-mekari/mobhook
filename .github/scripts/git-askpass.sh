#!/bin/sh
# GIT_ASKPASS helper: answers git's credential prompts from the environment so
# the token is never written to .git/config, argv, or the log.
# Contains no secret. Requires TAP_TOKEN in the environment.
case "$1" in
  Username*) printf '%s\n' "x-access-token" ;;
  Password*) printf '%s\n' "${TAP_TOKEN:?TAP_TOKEN is not set}" ;;
  *) exit 1 ;;
esac
