#!/bin/bash

mydir=`dirname "$0"`
#avoid // ugliness
if [[ "$mydir" == "/" ]]
then
    mydir=""
fi
#source the defaults, for the module name and nothing else
source "$mydir/auto_snap_defaults.sh"

#check for zfs in path, if not, add expected path
which zfs > /dev/null
if [[ $? != 0 ]]
then
    PATH="/usr/sbin:$PATH"
fi

readarray -t filesystems < <(zfs list -H -t filesystem,volume -o name)
for (( i = 0; i < ${#filesystems[@]}; ++i ))
do
    enablestring=`zfs get -Hp "$module:enable" "${filesystems[$i]}" | awk '{print $3}'`
    if [[ "$enablestring" == "true" ]]
    then
        "$mydir/auto_snap_core.sh" "${filesystems[$i]}"
    fi
done

