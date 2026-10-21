#!/usr/bin/env bash
set -e

# Install the crontab for the busybox cron daemon and start it in the background.
crontab /app/crontab
crond -b -l 8

# Hand off to the log capture script (PID 1 becomes capture_logs.sh via exec).
exec /app/capture_logs.sh