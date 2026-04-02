---
name: "VibeGuard: Stats"
description: "View hooks trigger statistics - interception/warning/release times and reason analysis"
category: VibeGuard
tags: [vibeguard, stats, logging, observability]
argument-hint: "[days|all|health [hours]]"
---

**Core Features**
- Analyze hook trigger logs in `~/.vibeguard/events.jsonl`
- Output interception/warning/release statistics, distribution by hook, top 5 reasons, and daily trigger volume
- Supports `health` snapshot mode: risk rate, Top risk hook, Top 10 recent risk events
- Help users understand whether VibeGuard is working and what is blocked

**Steps**

1. Run the corresponding script according to the parameters:
   ```bash
   if [[ "${ARGUMENTS:-}" == health* ]]; then
     health_arg="${ARGUMENTS#health}"
     health_arg="${health_arg#"${health_arg%%[![:space:]]*}"}"
     bash ~/Desktop/code/AI/tools/vibeguard/scripts/hook-health.sh "${health_arg:-24}"
   else
     bash ~/Desktop/code/AI/tools/vibeguard/scripts/stats.sh $ARGUMENTS
   fi
   ```
   Parameter description:
   - No parameters: Last 7 days
   - Number (e.g. 30): Last N days
   - `all`: all history
   - `health`: health snapshot of the last 24 hours
   - `health 72`: Health snapshot of the last 72 hours

2. Display the statistical results to the user. If there is an exception (such as interception is 0 but has been used for a period of time), you will be reminded to check whether the hooks configuration is correct.
