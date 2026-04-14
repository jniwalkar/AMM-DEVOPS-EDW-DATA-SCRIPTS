#!/bin/bash

YEAR=$(date +%Y)
MONTH=$(date +%m)
TODAY=$(date +%-d)

# Day of week for the 1st (1=Mon ... 7=Sun)
DOW=$(date -d "$YEAR-$MONTH-01" +%u)

if [[ $DOW -le 5 ]]; then
    FIRST_WORKDAY=1
elif [[ $DOW -eq 6 ]]; then
    FIRST_WORKDAY=3  # Saturday -> Monday
else
    FIRST_WORKDAY=2  # Sunday -> Monday
fi

if [[ "$TODAY" -eq "$FIRST_WORKDAY" ]]; then
    /path/to/your/actual_script.sh
fi