#!/bin/sh
# Runs inside Debian Installer before partman. No direct disk writes here.
set -e
. /usr/share/debconf/confmodule
debconf-loadtemplate library /library-target.templates
choices=
for disk in $(list-devices disk); do
    name=${disk##*/}
    sys=/sys/class/block/$name
    [ -r "$sys/removable" ] || continue
    [ "$(cat "$sys/removable")" = 0 ] || continue
    physical=$(readlink -f "$sys")
    case "$physical" in */usb*|*/virtual/*) continue ;; esac
    protected=false
    while read -r source mountpoint rest; do
        case "$mountpoint" in /cdrom|/hd-media|/isodevice)
            source=$(readlink -f "$source")
            mounted_sys=$(readlink -f "/sys/class/block/${source##*/}")
            case "$mounted_sys" in "$physical"|"$physical"/*) protected=true ;; esac
        ;; esac
    done < /proc/mounts
    [ "$protected" = false ] || continue
    model=$(cat "$sys/device/model" 2>/dev/null || echo 'Internal disk')
    # Commas separate debconf choices. Keep each choice on one line.
    model=$(echo "$model" | tr ',\n' '  ')
    sectors=$(cat "$sys/size")
    gib=$((sectors / 2097152))
    label="$disk - $model - ${gib} GiB"
    choices="${choices:+$choices, }$label"
done
if [ -z "$choices" ]; then
    db_input critical library/no-target || true
    db_go || true
    logger -t library-target 'No eligible internal target disk; refusing automatic partitioning'
    exit 1
fi
db_subst library/target CHOICES "$choices"
db_fset library/target seen false
db_input critical library/target || true
db_go || exit 1
db_get library/target
selected=$RET
# Match the choice to an enumerated disk before passing it to the partitioner.
valid=false
old_ifs=$IFS
IFS=,
for option in $choices; do
    option=$(echo "$option" | sed 's/^ *//')
    [ "$selected" = "$option" ] && valid=true
done
IFS=$old_ifs
[ "$valid" = true ] || exit 1
disk=${selected%% *}
[ -b "$disk" ] || exit 1
db_subst library/erase-confirm TARGET "$selected"
db_set library/erase-confirm false
db_fset library/erase-confirm seen false
db_input critical library/erase-confirm || true
db_go || exit 1
db_get library/erase-confirm
[ "$RET" = true ] || exit 1
db_set partman-auto/disk "$disk"
db_set grub-installer/bootdev "$disk"
db_fset grub-installer/bootdev seen true
logger -t library-target "Whole-disk Debian installation selected: $disk"
