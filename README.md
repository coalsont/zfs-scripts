zfs-scripts
===========

some useful scripts related to zfs

snapspace takes a filesystem as an argument, and reports how much data referenced by this snapshot is not in the current filesystem (as OLDREFS), the amount of that data that exists only in this snapshot (as UNIQUE, equal to the zfs "used" property), and the percentage of the old data that this unique data represents

Sample output:

SNAPSHOT                                    OLDREFS   UNIQUE    UNIQUE%
zfs-auto-snap_monthly-2014-05-09-17h07        8.53T     8.51T    99%
zfs-auto-snap_monthly-2014-06-09-17h07      368.94G   341.41G    92%
zfs-auto-snap_weekly-2014-07-07-17h07       677.10G    14.67G     2%
zfs-auto-snap_monthly-2014-07-09-17h09      676.68G    14.37G     2%
zfs-auto-snap_weekly-2014-07-16-17h09       714.96G    35.35G     4%
...

snapreport takes a snapshot with filesystem as an argument, and shows the breakdown of ONLY the data added between this snapshot and the next, arranged by which snapshot it was deleted immediately after ("unique" meaning deleted before the next remaining snapshot was taken, and "active" meaning has not been deleted)

Sample output:

ENDING SNAPSHOT                             SIZE
unique                                        8.51T
zfs-auto-snap_monthly-2014-06-09-17h07       23.03G
zfs-auto-snap_weekly-2014-07-07-17h07       338.59M
zfs-auto-snap_monthly-2014-07-09-17h09        1.11G
zfs-auto-snap_weekly-2014-07-16-17h09       914.56M
