zfs-scripts
===========

some useful scripts related to zfs

snapspace takes a filesystem as an argument, and shows you how much total "old" space is in each snapshot, as well as the "unique" amount reported by the "used" property

snapreport takes a snapshot with filesystem as an argument, and shows the breakdown of ONLY the data added before the next snapshot, by which snapshot it was deleted in

