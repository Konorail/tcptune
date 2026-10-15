#!/usr/bin/env bash
# Run on the actual client, or invoke this through an SSH --probe-command wrapper.
# Sourcing tcptune.sh only defines functions; it does not tune this client.
set -uo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/tcptune.sh"
if [ -z "${PROXY_HOST:-}" ] || [ -z "${PROXY_TEST_URL:-}" ] || [ -z "${PROXY_SMALL_URL:-}" ]; then
  printf 'Set PROXY_HOST, PROXY_TEST_URL and PROXY_SMALL_URL.\n' >&2
  exit 1
fi
_proxy_probe_impl
