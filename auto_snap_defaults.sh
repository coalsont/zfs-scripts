#!/bin/bash

#the prefix and date format string to use for snapshots
#if your prefix has characters that grep treats specially, put its escaped version into grepprefix
prefix="auto-snap-"
grepprefix="$prefix"
#date format to use normally, and a second format to use if it fails to take a snapshot because it already exists (usually due to daylight savings or other timezone change)
dateformat="%Y-%m-%d-%H:%M"
preexistformat="$dateformat%z"

#name of the "module" part of the user property to get extra config info from
#use "$module:prevent" with "snapshot" and/or "destroy" somewhere in the string to prevent the script from doing that operation
module="auto-snap"

#take snapshots even if there are no changes since last automatic snapshot
#value taken from "$module:keep-empty" if it is "true" or "false"
keepempty=1

#the following attributes are overridden by the comma separated list in the value of "$module:schedule"
#if snapshot time difference is within this number of SECONDS of being kept, keep it to allow for variance in when the script gets around to examining the filesystem
#this is the first element in "$module:schedule"
wiggle=60

#use initoffset if you want more of the "frequent" snapshots than is accounted for by schedule[0]
#that is, all auto snapshots younger than schedule[0] + offset + wiggle SECONDS will be kept
#this is the second element in "$module:schedule"
initoffset=-120

#the schedule as pairs of (interval, number) with interval in SECONDS
#this is overridden by the remainder of "$module:schedule", ie, third and later
#hourly
schedule[0]=3600
#keep 23
schedule[1]=23
#daily
schedule[2]=$(( schedule[0] * 24 ))
#keep 6
schedule[3]=6
#weekly
schedule[4]=$(( schedule[2] * 7 ))
#keep 3
schedule[5]=3
#quasi-monthly, 4 weeks - this script does NOT readjust weekly/monthly based on day of month, unlike time-slider
schedule[6]=$(( schedule[4] * 4 ))
#keep 11
schedule[7]=11

#sanity check schedule
if (( ${#schedule[@]} % 2 == 1 ))
then
    echo "error in defaults:" 1>&2
    echo "schedule has an odd number of elements" 1>&2
    exit 1
fi
if (( ${#schedule[@]} < 2 ))
then
    echo "error in defaults:" 1>&2
    echo "schedule must have at least 2 elements" 1>&2
    exit 1
fi

