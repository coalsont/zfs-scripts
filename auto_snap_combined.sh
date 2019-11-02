#!/bin/bash

#don't use u, because unset error from intentionally empty array is annoying to deal with
set -e

#debugging, used for zfs snapshot and destroy commands
dryrun=0
ignore_output=1
verbose=0

#check for zfs in path, if not, add expected path

if ! which zfs > /dev/null
then
    PATH="/usr/sbin:$PATH"
fi

#name of the "module" part of the user property to get extra config info from
#use "$module:prevent" with "snapshot" and/or "destroy" somewhere in the string to prevent the script from doing that operation
module="auto-snap"

function defaults()
{
    #the prefix and date format string to use for snapshots
    #if your prefix has characters that grep treats specially, put its escaped version into grepprefix
    #grepprefix is used to locate which snapshots were made by the script, so that it doesn't destroy manually taken snapshots
    prefix="auto-snap-"
    grepprefix="$prefix"
    #date format to use normally, and a second format to use if it fails to take a snapshot because it already exists (usually due to daylight savings or other timezone change)
    dateformat="%Y-%m-%d-%H:%M"
    preexistformat="$dateformat%z"
    
    #take snapshots even if there are no changes since last automatic snapshot
    #value taken from "$module:keep-empty" if it is "true" or "false"
    keepempty=1
    
    #below variables set the snapshot schedule, and are overridden by a comma-separated list in "$module:schedule", as specified
    
    #the following attributes are overridden by the comma separated list in the value of "$module:schedule"
    #if snapshot time difference is within this number of SECONDS of being kept, keep it to allow for variance in when the script gets around to examining the filesystem
    #this is the first element in "$module:schedule"
    wiggle=120
    
    #use initoffset if you want more of the "frequent" snapshots than is accounted for by schedule[0]
    #that is, all auto snapshots younger than schedule[0] + offset + wiggle SECONDS will be kept
    #this is the second element in "$module:schedule"
    initoffset=-240
    
    #the remainder of "$module:schedule" is used as the $schedule array, which is variable length, with an even number of elements
    
    #forget any previous modified schedule
    unset schedule
    #the schedule as pairs of (interval, number) with interval in SECONDS
    #this is overridden by the remainder of "$module:schedule", ie, third and later
    #hourly
    schedule[0]=3600
    #keep 23 (the 24th hour is within the frequents range)
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
    #keep 12 (28 * 13 = 364)
    schedule[7]=12
    
    #sanity check defaults
    if ! [[ "$wiggle" =~ ^-?[0-9]+$ ]]
    then
        echo "error in defaults:" 1>&2
        echo "invalid value for wiggle (first element of $module:schedule): '$wiggle'" 1>&2
        exit 1
    fi
    if ! [[ "$initoffset" =~ ^-?[0-9]+$ ]]
    then
        echo "error in defaults:" 1>&2
        echo "invalid value for initoffset (second element of $module:schedule): '$initoffset'" 1>&2
        exit 1
    fi
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
    local i
    for (( i = 0; i < ${#schedule[@]}; ++i ))
    do
        if ! [[ ${schedule[$i]} =~ ^-?[0-9]+$ ]]
        then
            echo "error in defaults:" 1>&2
            echo "found noninteger in schedule: ${schedule[$i]}" 1>&2
            exit 1
        fi
    done
}


function run_wrap()
{
    if (( dryrun ))
    then
        echo "dryrun: $*"
    else
        if (( verbose ))
        then
            echo "running: $*"
        fi
        if (( ignore_output ))
        then
            "$@" &> /dev/null
        else
            "$@"
        fi
    fi
}

function do_filesystem()
{
    if [[ $# != 1 ]]
    then
        echo "internal error: do_filesystem should be called with only one argument" 1>&2
        exit 1
    fi
    
    local filesystem="$1"
    
    #reload defaults, to overwrite any custom schedule another filesystem has
    defaults
    
    local confstring=`zfs get -Hp "$module:schedule" "$filesystem" | cut -f3`
    #NOTE: unset value returns "-", can't set empty string
    #so, expect at least 3 commas in it - wiggle, offset, first interval, first num to keep
    if [[ "$confstring" == *,*,*,* ]]
    then
        #these reads will succeed because we know 3 commas exist
        read newwiggle newinitoffset < <(echo "$confstring" | cut -f1-2 -d, | tr , ' ')
        read -a newschedule < <(echo "$confstring" | cut -f3- -d, | tr , ' ')
        #sanity check configuration - defaults function self-checks
        if ! [[ "$newwiggle" =~ ^-?[0-9]+$ ]]
        then
            echo "error in custom schedule of $filesystem:" 1>&2
            echo "invalid value for wiggle (first element of $module:schedule): '$wiggle'" 1>&2
            exit 1
        fi
        if ! [[ "$newinitoffset" =~ ^-?[0-9]+$ ]]
        then
            echo "error in custom schedule of $filesystem:" 1>&2
            echo "invalid value for initoffset (second element of $module:schedule): '$initoffset'" 1>&2
            exit 1
        fi
        if (( ${#newschedule[@]} % 2 == 1 ))
        then
            echo "error in custom schedule of $filesystem:" 1>&2
            echo "$module:schedule has an odd number of elements" 1>&2
            exit 1
        fi
        if (( ${#newschedule[@]} < 2 ))
        then
            echo "error in custom schedule of $filesystem:" 1>&2
            echo "$module:schedule must have at least 4 elements" 1>&2
            exit 1
        fi
        local i
        for (( i = 0; i < ${#newschedule[@]}; ++i ))
        do
            if ! [[ ${newschedule[$i]} =~ ^-?[0-9]+$ ]]
            then
                echo "error in custom schedule of $filesystem:" 1>&2
                echo "found noninteger in $module:schedule: ${schedule[$i]}" 1>&2
                exit 1
            fi
        done
        
        wiggle=$newwiggle
        initoffset=$newinitoffset
        schedule=("${newschedule[@]}")
    else
        if [[ "$confstring" != "-" ]]
        then
            echo "warning: unrecognized value '$confstring' for $module:schedule (expected integers separated by commas) in filesystem $filesystem"
            echo "using default settings"
        fi
    fi
    
    local keepemptystring=`zfs get -Hp "$module:keep-empty" "$filesystem" | cut -f3`
    if [[ "$keepemptystring" == "true" ]]
    then
        keepempty=1
    else
        if [[ "$keepemptystring" == "false" ]]
        then
            keepempty=0
        else
            if [[ "$keepemptystring" != "-" ]]
            then
                echo "warning: unrecognized value '$keepemptystring' for $module:keep-empty (expected 'true' or 'false') in filesystem $filesystem"
            fi
        fi
    fi
    
    local keepsincestring=$(zfs get -Hp "$module:keep-since" "$filesystem" | cut -f3)
    local keepsincetime=-1
    if [[ "$keepsincestring" != "-" ]]
    then
        keepsincetime=$(zfs get -Hp creation "$filesystem@$keepsincestring" 2>/dev/null | cut -f3)
        if [[ "$keepsincetime" == "" ]]
        then
            keepsincetime=-1
        fi
    fi
    
    #when keepempty=0, do snapshot *after* cleanup, see below
    #when keepempty=1, take snapshot first to reduce jitter
    if [[ $keepempty == 1 ]]
    then
        #snapshot if it isn't in the prevent attribute - redirect output of zfs snapshot so that existing ones attempted due to daylight savings or other time adjustments produce no warning
        if [[ `zfs get -Hp "$module:prevent" "$filesystem" | cut -f3` != *snapshot* ]]
        then
            if ! run_wrap pfexec zfs snapshot "$filesystem@$prefix"`date +"$dateformat"`
            then
                run_wrap pfexec zfs snapshot "$filesystem@$prefix"`date +"$preexistformat"` || true
            fi
        fi
    fi
    
    #clean up old snaps if destroy isn't in the prevent attribute - this goes by creation time, which is in seconds since epoch, daylight savings/time zone has no effect, though UTC adjustments will
    if [[ `zfs get -Hp "$module:prevent" "$filesystem" | cut -f3` != *destroy* ]]
    then
        local snapindex=0
        local curtime=`date +%s`
        local -a allsnaps snaps snaptimes
        local i interindex
        #use readarray to keep whitespace intact, if someone decided to use it in snapshots or prefix
        readarray -t allsnaps < <(zfs list -H -t snapshot -d 1 -o name -S creation "$filesystem" | cut -f2- -d@ | grep "^$grepprefix")
        #ignore all snapshots in the frequent interval, and collect snapshot creation timestamps
        #also ignore snapshots after the specified one, inclusive
        for (( i = 0; i < ${#allsnaps[@]}; ++i ))
        do
            local snap="${allsnaps[$i]}"
            local snaptime=`zfs get -Hp creation "$filesystem@$snap" | cut -f3`
            if [[ $snaptime == "" ]] || (( curtime - snaptime < schedule[0] + initoffset + wiggle )) || ((keepsincetime >= 0 && snaptime >= keepsincetime))
            then
                continue
            fi
            snaps[$snapindex]="$snap"
            snaptimes[$snapindex]=$snaptime
            local snapindex=$(( snapindex + 1 ))
        done
        #resolving which snaps to keep in the given timeframe should start from oldest in interval
        local startsnap=0
        local lasttime=$(( curtime - schedule[0] - initoffset ))
        for (( interindex = 0; interindex < ${#schedule[@]}; interindex += 2 ))
        do
            if (( schedule[interindex + 1] < 1 ))
            then
                local endsnap=$(( ${#snaps[@]} ))
            else
                local cutofftime=$(( lasttime - schedule[interindex] * schedule[interindex + 1] ))
                local lasttime=$cutofftime
                local endsnap=$startsnap
                while (( endsnap < ${#snaps[@]} )) && (( snaptimes[endsnap] + wiggle > cutofftime ))
                do
                    local endsnap=$(( endsnap + 1 ))
                done
            fi
            if (( endsnap != startsnap ))
            then
                local prevsnaptime=$(( snaptimes[endsnap - 1] ))
                for (( i = endsnap - 2; i >= startsnap; --i ))
                do
                    if (( snaptimes[i] - prevsnaptime + wiggle < schedule[interindex] ))
                    then
                        run_wrap pfexec zfs destroy "$filesystem@${snaps[$i]}" || true
                    else
                        local prevsnaptime=$(( snaptimes[i] ))
                    fi
                done
            fi
            local startsnap=$endsnap
            if (( schedule[interindex + 1] < 1 ))
            then
                #don't try to do the next interval if this interval has a count of -1
                #also used to signal to final cleanup loop that it shouldn't execute (in case the interval list is malformed)
                break;
            fi
        done
        #remove all older snaps if we didn't hit a -1 in the number array
        if (( interindex >= ${#schedule[@]} ))
        then
            while (( startsnap < ${#snaps[@]} ))
            do
                run_wrap pfexec zfs destroy "$filesystem@${snaps[$startsnap]}" || true
                local startsnap=$(( startsnap + 1 ))
            done
        fi
    fi
    
    #when keepempty=0, do cleanup before snapshot in case most recent snapshot gets destroyed due to a very inactive filesystem
    #otherwise, it will take until next run to realize the filesystem has changes since the oldest surviving snapshot
    if [[ $keepempty == 0 ]]
    then
        #snapshot if it isn't in the prevent attribute - redirect output of zfs snapshot so that existing ones attempted due to daylight savings or other time adjustments produce no warning
        if [[ `zfs get -Hp "$module:prevent" "$filesystem" | cut -f3` != *snapshot* ]]
        then
            local latest=`zfs list -H -t snapshot -d 1 -o name -S creation "$filesystem" | cut -f2- -d@ |grep "^$grepprefix" |  head -n 1`
            if [[ $latest == "" || `zfs get -Hp written@"$latest" "$filesystem" | cut -f3` != 0 || `zfs get -Hp used "$filesystem@$latest" | cut -f3` != 0 ]]
            then
                if ! run_wrap pfexec zfs snapshot "$filesystem@$prefix"`date +"$dateformat"`
                then
                    run_wrap pfexec zfs snapshot "$filesystem@$prefix"`date +"$preexistformat"` || true
                fi
            fi
        fi
    fi
}

#BEGIN RUNALL

readarray -t filesystems < <(zfs list -H -t filesystem,volume -o name)
for (( i = 0; i < ${#filesystems[@]}; ++i ))
do
    enablestring=`zfs get -Hp "$module:enable" "${filesystems[$i]}" | cut -f3`
    if [[ "$enablestring" == "true" ]]
    then
        do_filesystem "${filesystems[$i]}" &
    fi
done

wait
