#!/bin/sh

# Find all PIDs of processes containing 'myprocess' in their command line
pids=$(ps | grep '[./]pppwn' | grep -v grep | awk '{print $1}')

# Check if pids variable is empty
if [ -z "$pids" ]; then
  echo "---"
else
  # Kill each PID found
  echo "$pids" | xargs kill -9
  echo "Killed the following PIDs: $pids"
fi

echo "none" > /sys/class/leds/tp-link:green:3g/trigger
