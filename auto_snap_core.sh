#!/bin/bash

if [[ $# != 1 ]]
then
    echo "usage: $0 <filesystem>" 1>&2
    exit 1
fi

filesystem="$1"
mydir=`dirname "$0"`
#avoid // ugliness
if [[ "$mydir" == "/" ]]
then
    mydir=""
fi
source "$mydir/auto_snap_defaults.sh"

#check for zfs in path, if not, add expected path
which zfs > /dev/null
if [[ $? != 0 ]]
then
    PATH="/usr/sbin:$PATH"
fi

confstring=`zfs get -Hp "$module:schedule" "$filesystem" | awk '{print $3}'`
#NOTE: unset value returns "-", set to empty string might do something else, making this tricky to test for
#so, expect at least 3 commas in it - wiggle, offset, first interval, first num to keep
if [[ "$confstring" == *,*,*,* ]]
then
    #if we fail to get settings from the string, exit with error, do not try to continue
    read wiggle offset < <(echo "$confstring" | cut -f1-2 -d, | tr , ' ')
    read -a schedule < <(echo "$confstring" | cut -f3- -d, | tr , ' ')
fi

keepemptystring=`zfs get -Hp "$module:keep-empty" "$filesystem" | awk '{print $3}'`
if [[ "$keepemptystring" == "true" ]]
then
    keepempty=1
else
    if [[ "$keepemptystring" == "false" ]]
    then
        keepempty=0
    fi
fi

#sanity check configuration - error messages assume that the zfs attribute is wrong, rather than the defaults script
if ! [[ "$wiggle" =~ ^-?[0-9]+$ ]]
then
    echo "error running $0 on $filesystem:" 1>&2
    echo "invalid value for wiggle (first element of $module:schedule): '$wiggle'" 1>&2
    exit 1
fi
if ! [[ "$initoffset" =~ ^-?[0-9]+$ ]]
then
    echo "error running $0 on $filesystem:" 1>&2
    echo "invalid value for initoffset (second element of $module:schedule): '$initoffset'" 1>&2
    exit 1
fi
if (( ${#schedule[@]} % 2 == 1 ))
then
    echo "error running $0 on $filesystem:" 1>&2
    echo "$module:schedule has an odd number of elements" 1>&2
    exit 1
fi
if (( ${#schedule[@]} < 2 ))
then
    echo "error running $0 on $filesystem:" 1>&2
    echo "$module:schedule must have at least 4 elements" 1>&2
    exit 1
fi
for (( i = 0; i < ${#schedule[@]}; ++i ))
do
    if ! [[ ${schedule[$i]} =~ ^-?[0-9]+$ ]]
    then
        echo "error running $0 on $filesystem:" 1>&2
        echo "found noninteger in $module:schedule: ${schedule[$i]}" 1>&2
        exit 1
    fi
done

#do cleanup before snapshot in case most recent snapshot gets destroyed due to keep-empty and a very inactive filesystem
#otherwise, between runs there will be changes since last snapshot, despite last snapshot being older than the frequent range

#clean up old snaps if destroy isn't in the prevent attribute - this goes by creation time, which is in seconds since epoch, daylight savings/time zone has no effect, though UTC adjustments will
if [[ `zfs get -Hp "$module:prevent" "$filesystem" | awk '{print $3}'` != *destroy* ]]
then
    snapindex=0
    curtime=`date +%s`
    #use readarray to keep whitespace intact, if someone decided to use it in snapshots or prefix
    readarray -t allsnaps < <(zfs list -H -t snapshot -d 1 -o name -S creation "$filesystem" | cut -f2- -d@ | grep "^$grepprefix")
    for (( i = 0; i < ${#allsnaps[@]}; ++i ))
    do
        snap="${allsnaps[$i]}"
        snaptime=`zfs get -Hp creation "$filesystem@$snap" | awk '{print $3}'`
        if [[ $snaptime == "" ]] || (( curtime - snaptime < schedule[0] + initoffset + wiggle ))
        then
            continue
        fi
        snaps[$snapindex]="$snap"
        snaptimes[$snapindex]=$snaptime
        snapindex=$(( snapindex + 1 ))
    done
    #resolving which snaps to keep in the given timeframe should start from oldest in interval
    startsnap=0
    lasttime=$(( curtime - schedule[0] - initoffset ))
    for (( interindex = 0; interindex < ${#schedule[@]}; interindex += 2 ))
    do
        if (( schedule[interindex + 1] < 1 ))
        then
            endsnap=$(( ${#snaps[@]} ))
        else
            cutofftime=$(( lasttime - schedule[interindex] * schedule[interindex + 1] ))
            lasttime=$cutofftime
            endsnap=$startsnap
            while (( endsnap < ${#snaps[@]} )) && (( snaptimes[endsnap] + wiggle > cutofftime ))
            do
                endsnap=$(( endsnap + 1 ))
            done
        fi
        if (( endsnap != startsnap ))
        then
            prevsnaptime=$(( snaptimes[endsnap - 1] ))
            for (( i = endsnap - 2; i >= startsnap; --i ))
            do
                if (( snaptimes[i] - prevsnaptime + wiggle < schedule[interindex] ))
                then
                    #redirect destroy output in case there are holds
                    pfexec zfs destroy "$filesystem@${snaps[$i]}" &> /dev/null
                else
                    prevsnaptime=$(( snaptimes[i] ))
                fi
            done
        fi
        startsnap=$endsnap
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
            pfexec zfs destroy "$filesystem@${snaps[$startsnap]}" &> /dev/null
            startsnap=$(( startsnap + 1 ))
        done
    fi
fi

#snapshot if it isn't in the prevent attribute - redirect output of zfs snapshot so that existing ones attempted due to daylight savings or other time adjustments produce no output
if [[ `zfs get -Hp "$module:prevent" "$filesystem" | awk '{print $3}'` != *snapshot* ]]
then
    if [[ $keepempty == 0 ]]
    then
        latest=`zfs list -H -t snapshot -d 1 -o name -S creation "$filesystem" | cut -f2- -d@ |grep "^$grepprefix" |  head -n 1`
        if [[ $latest == "" || `zfs get -Hp written@"$latest" "$filesystem" | awk '{print $3}'` != 0 || `zfs get -Hp used "$filesystem@$latest" | awk '{print $3}'` != 0 ]]
        then
            pfexec zfs snapshot "$filesystem@$prefix"`date +"$dateformat"` &> /dev/null
            if [[ $? != 0 ]]
            then
                pfexec zfs snapshot "$filesystem@$prefix"`date +"$preexistformat"` &> /dev/null
            fi
        fi
    else
        pfexec zfs snapshot "$filesystem@$prefix"`date +"$dateformat"` &> /dev/null
        if [[ $? != 0 ]]
        then
            pfexec zfs snapshot "$filesystem@$prefix"`date +"$preexistformat"` &> /dev/null
        fi
    fi
fi

