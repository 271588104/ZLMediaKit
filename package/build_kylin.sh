#!/usr/bin/env bash
set -euo pipefail

exec bash "$(dirname "$0")/build_linux_x86_64.sh" kylin-v10
