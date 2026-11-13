#!/bin/sh
# Print the device of the USB media stick, or nothing if there is none.
#
# Takes the first hot-pluggable partition (or unpartitioned stick) with a
# filesystem, skipping every disk that has something mounted: a Pi that boots
# from USB has its own system disk on the bus too, and that is never the stick.
set -eu

# lsblk -P prints KEY="value" pairs, so empty fields cannot shift columns;
# split on '"': $2 NAME, $4 PKNAME, $6 HOTPLUG, $8 TYPE, $10 FSTYPE, $12 MOUNTPOINT.
lsblk -Ppno NAME,PKNAME,HOTPLUG,TYPE,FSTYPE,MOUNTPOINT | awk -F'"' '
  { disk = ($4 != "" ? $4 : $2); name[NR] = $2; dsk[NR] = disk
    hot[NR] = $6; type[NR] = $8; fs[NR] = $10
    if ($12 != "") busy[disk] = 1 }
  END { for (i = 1; i <= NR; i++)
          if (hot[i] == 1 && (type[i] == "part" || type[i] == "disk") && !(dsk[i] in busy) &&
              fs[i] ~ /^(vfat|exfat|ntfs|ntfs3|ext[234])$/) { print name[i]; exit } }'
