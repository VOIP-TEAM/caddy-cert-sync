#!/bin/bash
in_maintenance_window() {
    local hour
    hour=$(date +%H | sed 's/^0//')
    [ -z "$hour" ] && hour=0
    if [ "$WINDOW_START" -le "$WINDOW_END" ]; then
        [ "$hour" -ge "$WINDOW_START" ] && [ "$hour" -lt "$WINDOW_END" ]
    else
        [ "$hour" -ge "$WINDOW_START" ] || [ "$hour" -lt "$WINDOW_END" ]
    fi
}
