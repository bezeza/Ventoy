#!/bin/sh

#Ventoy partition 32MB
VENTOY_PART_SIZE=33554432
VENTOY_PART_SIZE_MB=32
VENTOY_SECTOR_SIZE=512
VENTOY_SECTOR_NUM=65536

ventoy_false() {
    [ "1" = "2" ]
}

ventoy_true() {
    [ "1" = "1" ]
}


vtinfo() {
    echo -e "\033[32m$*\033[0m"
}

vtwarn() {
    echo -e "\033[33m$*\033[0m"
}


vterr() {
    echo -e "\033[31m$*\033[0m"
}

vtdebug() {
    echo "$*" >> ./log.txt
}

vtoy_gen_uuid() {
    if  uuid -F BIN > /dev/null 2>&1; then
        uuid -F BIN
    elif uuidgen -V > /dev/null 2>&1; then
        a=$(uuidgen | sed 's/-//g')
        echo -en "\x${a:0:2}\x${a:2:2}\x${a:4:2}\x${a:6:2}\x${a:8:2}\x${a:10:2}\x${a:12:2}\x${a:14:2}\x${a:16:2}\x${a:18:2}\x${a:20:2}\x${a:22:2}\x${a:24:2}\x${a:26:2}\x${a:28:2}\x${a:30:2}"        
    elif python -V > /dev/null 2>&1; then
        a=$(python -c 'import sys,uuid; sys.stdout.write(uuid.uuid4().hex)')
        echo -en "\x${a:0:2}\x${a:2:2}\x${a:4:2}\x${a:6:2}\x${a:8:2}\x${a:10:2}\x${a:12:2}\x${a:14:2}\x${a:16:2}\x${a:18:2}\x${a:20:2}\x${a:22:2}\x${a:24:2}\x${a:26:2}\x${a:28:2}\x${a:30:2}"
    elif [ -e /dev/urandom ]; then
        dd if=/dev/urandom bs=1 count=16 status=none
    else
        datestr=$(date +%N%N%N%N%N)
        a=${datestr:0:32}
        echo -en "\x${a:0:2}\x${a:2:2}\x${a:4:2}\x${a:6:2}\x${a:8:2}\x${a:10:2}\x${a:12:2}\x${a:14:2}\x${a:16:2}\x${a:18:2}\x${a:20:2}\x${a:22:2}\x${a:24:2}\x${a:26:2}\x${a:28:2}\x${a:30:2}"
    fi
}

check_tool_work_ok() {
    
    if echo 1 | hexdump > /dev/null; then
        vtdebug "hexdump test ok ..."
    else
        vtdebug "hexdump test fail ..."
        ventoy_false
        return
    fi
   
    if mkexfatfs -V > /dev/null; then        
        vtdebug "mkexfatfs test ok ..."
    else
        vtdebug "mkexfatfs test fail ..."
        ventoy_false
        return
    fi
    
    if vtoycli fat -T; then
        vtdebug "vtoycli fat test ok ..."
    else
        vtdebug "vtoycli fat test fail ..."
        ventoy_false
        return
    fi
    
    vtdebug "tool check success ..."
    ventoy_true
}


get_disk_part_name() {
    DISK=$1
    
    if echo $DISK | grep -q "/dev/loop"; then
        echo ${DISK}p${2}
    elif echo $DISK | grep -q "/dev/nvme[0-9][0-9]*n[0-9]"; then
        echo ${DISK}p${2}
    elif echo $DISK | grep -q "/dev/mmcblk[0-9]"; then
        echo ${DISK}p${2}
    elif echo $DISK | grep -q "/dev/nbd[0-9]"; then
        echo ${DISK}p${2}
    elif echo $DISK | grep -q "/dev/zd[0-9]"; then
        echo ${DISK}p${2}
    elif echo $DISK | grep -q "/dev/md[0-9]"; then
        echo ${DISK}p${2}
    else
        echo ${DISK}${2}
    fi
}

# Return the selected block device and all block devices that depend on it,
# including partitions, holders (for example dm/LVM and MD RAID), and slaves.
# The sysfs root can be overridden by tests; production uses /sys/class/block.
ventoy_get_related_block_devices() {
    vgr_disk=$1
    vgr_sysfs=${VENTOY_SYSFS_ROOT:-/sys/class/block}
    vgr_name=${vgr_disk#/dev/}

    if [ -z "$vgr_name" ] || [ ! -e "$vgr_sysfs/$vgr_name/dev" ]; then
        return 1
    fi

    vgr_pending=$vgr_name
    vgr_seen=""

    while [ -n "$vgr_pending" ]; do
        vgr_current=${vgr_pending%% *}
        if [ "$vgr_pending" = "$vgr_current" ]; then
            vgr_pending=""
        else
            vgr_pending=${vgr_pending#* }
        fi

        case " $vgr_seen " in
            *" $vgr_current "*) continue ;;
        esac
        vgr_seen="${vgr_seen}${vgr_seen:+ }$vgr_current"

        vgr_current_path=$(readlink -f "$vgr_sysfs/$vgr_current" 2>/dev/null)
        if [ -z "$vgr_current_path" ]; then
            return 1
        fi

        # Add partitions belonging to this block device. Comparing resolved
        # sysfs paths avoids false prefix matches such as sda vs sdaa.
        for vgr_candidate in "$vgr_sysfs"/*; do
            [ -e "$vgr_candidate/partition" ] || continue
            vgr_candidate_path=$(readlink -f "$vgr_candidate" 2>/dev/null)
            case "$vgr_candidate_path" in
                "$vgr_current_path"/*)
                    vgr_candidate_name=${vgr_candidate##*/}
                    case " $vgr_seen $vgr_pending " in
                        *" $vgr_candidate_name "*) ;;
                        *) vgr_pending="${vgr_pending}${vgr_pending:+ }$vgr_candidate_name" ;;
                    esac
                    ;;
            esac
        done

        # Walk both directions of the block-device dependency graph. This
        # catches active LVM/dm-crypt and MD RAID users of the selected disk.
        for vgr_relation in holders slaves; do
            for vgr_link in "$vgr_sysfs/$vgr_current/$vgr_relation"/*; do
                [ -e "$vgr_link" ] || continue
                vgr_link_name=${vgr_link##*/}
                case " $vgr_seen $vgr_pending " in
                    *" $vgr_link_name "*) ;;
                    *) vgr_pending="${vgr_pending}${vgr_pending:+ }$vgr_link_name" ;;
                esac
            done
        done
    done

    printf '%s\n' "$vgr_seen"
}

# Refuse to operate on a disk that is mounted or used by active swap, either
# directly or through a partition/device-mapper/RAID dependency.
ventoy_check_disk_busy() {
    vcdb_disk=$1
    vcdb_sysfs=${VENTOY_SYSFS_ROOT:-/sys/class/block}
    vcdb_mountinfo=${VENTOY_PROC_MOUNTINFO:-/proc/self/mountinfo}
    vcdb_swaps=${VENTOY_PROC_SWAPS:-/proc/swaps}

    vcdb_related=$(ventoy_get_related_block_devices "$vcdb_disk") || {
        vterr "Unable to inspect block-device dependencies for $vcdb_disk. Refusing to continue."
        return 1
    }

    if [ ! -r "$vcdb_mountinfo" ]; then
        vterr "Unable to read $vcdb_mountinfo. Refusing to write to $vcdb_disk."
        return 1
    fi

    for vcdb_name in $vcdb_related; do
        vcdb_dev=$(cat "$vcdb_sysfs/$vcdb_name/dev" 2>/dev/null)
        [ -n "$vcdb_dev" ] || continue
        vcdb_mount=$(awk -v dev="$vcdb_dev" '$3 == dev { print $5; exit }' "$vcdb_mountinfo")
        if [ -n "$vcdb_mount" ]; then
            vcdb_mount=$(printf '%b' "$vcdb_mount")
            vterr "$vcdb_disk is in use: /dev/$vcdb_name is mounted at $vcdb_mount. Unmount it first."
            return 1
        fi
    done

    if [ ! -r "$vcdb_swaps" ]; then
        vterr "Unable to read $vcdb_swaps. Refusing to write to $vcdb_disk."
        return 1
    fi

    # /proc/swaps has a header followed by one active swap entry per line.
    {
        IFS= read -r vcdb_header || vcdb_header=""
        while IFS=' ' read -r vcdb_swap vcdb_type vcdb_size vcdb_used vcdb_priority; do
            [ -n "$vcdb_swap" ] || continue
            vcdb_swap=$(printf '%b' "$vcdb_swap")
            vcdb_swap_dev=""

            case "$vcdb_swap" in
                /dev/*)
                    vcdb_real=$(readlink -f "$vcdb_swap" 2>/dev/null)
                    if [ -n "$vcdb_real" ]; then
                        vcdb_swap_name=${vcdb_real#/dev/}
                        vcdb_swap_dev=$(cat "$vcdb_sysfs/$vcdb_swap_name/dev" 2>/dev/null)
                    fi
                    if [ -z "$vcdb_swap_dev" ]; then
                        vterr "Unable to identify active swap device $vcdb_swap. Refusing to continue."
                        returnBBÎÂ
BÈÝØ\[\È\HX\YÝYÚZ\ÛÛZ[[È[\Þ\Ý[KÈY[[Ø[ÝY[YHHXÚÚ[È]XÙKZ[ÛÜÙYYÛÛ[X[][[Ù]Û[NÈ[ÙÜÝØ\Ù]I
[[[[ÈPRRSK]\Ù]ÙÜÝØ\Ù]Û[ÙY[	Ì\	ÊBBYÈ^ÙÜÝØ\Ù]NÈ[\[XHÈY[YHH[\Þ\Ý[HÛÛZ[[ÈXÝ]HÝØ\[H	ÙÜÝØ\[Ý[[[Ü\ØXHÝØ\YÜHÛÛ[Z[Ë]\BBÎÂ\ØXÂÜÙÛ[YH[	ÙÜ[]YÈÂÙÙ]I
Ø]ÙÜÞ\ÙËÉÙÛ[YKÙ]Ù]Û[
BYÈ[ÙÙ]H	ÈÙÙ]HÙÜÝØ\Ù]NÈ[\ÙÙ\ÚÈ\È[\ÙH\ÈÝØ\ÝYÚ	ÙÜÝØ\[ÝØ\Ù\Ý]\BBÛBÛBHÙÜÝØ\È]\BÈ[[Ý[ÛHHÙ[XÝY]XÙH[]ÈXÝX[\][ÛË]XÙK[[X\ÈX]Ú[È][ÈY^ÛÛ\Ú[ÛÈ
Ü^[\HÙ]ÜÙHX]Ú[ÈÙ]ÜÙXLJKÚXÚ×Ý[[Ý[Ù\ÚÊ
HÂ\ÚÓÜ\HHYÜÞ\ÙÏIÕSÖWÔÖTÑ×ÔÓÕKÜÞ\ËØÛ\ÜËØØÚßBYÛ[Ý[[ÏIÕSÖWÔÐ×ÓSÕSSÎKÜØËÜÙ[Û[Ý[[ßBYÛ[YOIÑ\ÚÓÜ\ËÙ]ßBÈYHYÜÞ\ÙËÉYÛ[YKÙ]H]\YÙ\Ú×Ü]I
XY[ÈYYÜÞ\ÙËÉYÛ[YHÙ]Û[
H]\ÜYÙ]XÙH[YÛ[YHÈÂYÙ]I
Ø]YÜÞ\ÙËÉYÙ]XÙKÙ]Ù]Û[
BÈ[YÙ]HÛÛ[YB]ÚÈ]]HYÙ]	ÉÈOH]È[	HIÈYÛ[Ý[[ÈÙ]Û[ÛHÚ[HQÏHXY\YÛ[Ý[ÈÂÈ[YÛ[Ý[HÛÛ[YBYÛ[Ý[I
[	ÉXÈYÛ[Ý[BXYÈZ[ÈÈ[[Ý[	YÛ[Ý[[[Ý[YÛ[Ý[Ù]Û[BÛBÜYØØ[Y]H[YÜÞ\ÙÈÊÈÂÈYHYØØ[Y]KÜ\][ÛHÛÛ[YBYØØ[Y]WÜ]I
XY[ÈYYØØ[Y]HÙ]Û[
BØ\ÙHYØØ[Y]WÜ][YÙ\Ú×Ü]ÊBYÙ]XÙOIÝYØØ[Y]HÈÊßBYÙ]I
Ø]YÜÞ\ÙËÉYÙ]XÙKÙ]Ù]Û[
BÈ[YÙ]HÛÛ[YB]ÚÈ]]HYÙ]	ÉÈOH]È[	HIÈYÛ[Ý[[ÈÙ]Û[ÎÂ\ØXÂÛHÚ[HQÏHXY\YÛ[Ý[ÈÂÈ[YÛ[Ý[HÛÛ[YBYÛ[Ý[I
[	ÉXÈYÛ[Ý[BXYÈZ[ÈÈ[[Ý[	YÛ[Ý[[[Ý[YÛ[Ý[Ù]Û[BÛBB

get_ventoy_version_from_cfg() {
    if grep -q 'set.*VENTOY_VERSION=' $1; then
        grep 'set.*VENTOY_VERSION=' $1 | awk -F'"' '{print $2}'
    else
        echo 'none'
    fi
}

is_disk_contains_ventoy() {
    DISK=$1    
    
    PART1=$(get_disk_part_name $1 1)  
    PART2=$(get_disk_part_name $1 2)  
    
    if [ -e /sys/class/block/${PART2#/dev/}/size ]; then    
        SIZE=$(cat /sys/class/block/${PART2#/dev/}/size)
    else
        SIZE=0
    fi

    if ! [ -b $PART1 ]; then
        vtdebug "$PART1 not exist"
        ventoy_false
        return
    fi
    
    if ! [ -b $PART2 ]; then
        vtdebug "$PART2 not exist"
        ventoy_false
        return
    fi
    
    PART1_TYPE=$(dd if=$DISK bs=1 count=1 skip=450 status=none | hexdump -n1 -e  '1/1 "%02X"')
    PART2_TYPE=$(dd if=$DISK bs=1 count=1 skip=466 status=none | hexdump -n1 -e  '1/1 "%02X"')
    
    # if [ "$PART1_TYPE" != "EE" ]; then
        # if [ "$PART2_TYPE" != "EF" ]; then
            # vtdebug "part2 type is $PART2_TYPE not EF"
            # ventoy_false
            # return
        # fi
    # fi
    
    # PART1_TYPE=$(dd if=$DISK bs=1 count=1 skip=450 status=none | hexdump -n1 -e  '1/1 "%02X"')
    # if [ "$PART1_TYPE" != "07" ]; then
        # vtdebug "part1 type is $PART2_TYPE not 07"
        # ventoy_false
        # return
    # fi
    
    if [ -e /sys/class/block/${PART1#/dev/}/start ]; then
        PART1_START=$(cat /sys/class/block/${PART1#/dev/}/start)
    fi
    
    if [ "$PART1_START" != "2048" ]; then
        vtdebug "part1 start is $PART1_START not 2048"
        ventoy_false
        return
    fi 
    
    if [ "$VENTOY_SECTOR_NUM" != "$SIZE" ]; then
        vtdebug "part2 size is $SIZE not $VENTOY_SECTOR_NUM"
        ventoy_false
        return
    fi
    
    ventoy_true
}

check_disk_secure_boot() {
    if ! is_disk_contains_ventoy $1; then
        ventoy_false
        return
    fi
    
    PART2=$(get_disk_part_name $1 2)    
    
    vtoycli fat -s $PART2
}

get_disk_ventoy_version() {

    if ! is_disk_contains_ventoy $1; then
        ventoy_false
        return
    fi
    
    PART2=$(get_disk_part_name $1 2)    
    
    ParseVer=$(vtoycli fat $PART2)
    if [ $? -eq 0 ]; then
        vtdebug "Ventoy version in $PART2 is $ParseVer"
        echo $ParseVer
        ventoy_true
        return
    fi
    
    ventoy_false
}

wait_and_create_part() {
    vPART1=$1
    vPART2=$2
    echo 'Wait for partitions $vPART1 and $vPART2 ...'
    for i in 0 1 2 3 4 5 6 7 8 9; do
        if ls -l $vPART1 2>/dev/null | grep -q '^b'; then
            if ls -l $vPART2 2>/dev/null | grep -q '^b'; then
                break
            fi
        else
            echo "Wait for $vPART1 and $vPART2 ..."
            sleep 1
        fi
    done

    if ls -l $vPART1 2>/dev/null | grep -q '^b'; then
        echo "$vPART1 exist OK"
    else
        MajorMinor=$(sed "s/:/ /" /sys/class/block/${vPART1#/dev/}/dev)        
        echo "mknod -m 0660 $vPART1 b $MajorMinor ..."
        mknod -m 0660 $vPART1 b $MajorMinor
    fi
    
    if ls -l $vPART2 2>/dev/null | grep -q '^b'; then
        echo "$vPART2 exist OK"
    else
        MajorMinor=$(sed "s/:/ /" /sys/class/block/${vPART2#/dev/}/dev)        
        echo "mknod -m 0660 $vPART2 b $MajorMinor ..."
        mknod -m 0660 $vPART2 b $MajorMinor        
    fi

    if ls -l $vPART1 2>/dev/null | grep -q '^b'; then
        if ls -l $vPART2 2>/dev/null | grep -q '^b'; then
            echo "partition exist OK"
        fi
    else
        echo "[FAIL] $vPART1/$vPART2 does not exist"
        exit 1
    fi
}


format_ventoy_disk_mbr() {
    reserve_mb=$1
    DISK=$2
    PARTTOOL=$3
    
    PART1=$(get_disk_part_name $DISK 1)
    PART2=$(get_disk_part_name $DISK 2)
    
    sector_num=$(cat /sys/block/${DISK#/dev/}/size)
    
    part1_start_sector=2048 
    
    if [ $reserve_mb -gt 0 ]; then
        reserve_sector_num=$(expr $reserve_mb \* 2048)
        part1_end_sector=$(expr $sector_num - $reserve_sector_num - $VENTOY_SECTOR_NUM - 1)
    else
        part1_end_sector=$(expr $sector_num - $VENTOY_SECTOR_NUM - 1)
    fi
    
    part2_start_sector=$(expr $part1_end_sector + 1)
    
    modsector=$(expr $part2_start_sector % 8)
    if [ $modsector -gt 0 ]; then
        vtdebug "modsector:$modsector need to be aligned with 4KB"
        part1_end_sector=$(expr $part1_end_sector - $modsector)
        part2_start_sector=$(expr $part1_end_sector + 1)
    fi
    
    part2_end_sector=$(expr $part2_start_sector + $VENTOY_SECTOR_NUM - 1)

    export part2_start_sector

    vtdebug "part1_start_sector=$part1_start_sector  part1_end_sector=$part1_end_sector"
    vtdebug "part2_start_sector=$part2_start_sector  part2_end_sector=$part2_end_sector"

    if [ -e $PART1 ]; then
        echo "delete $PART1"
        rm -f $PART1
    fi

    if [ -e $PART2 ]; then
        echo "delete $PART2"
        rm -f $PART2
    fi

    echo ""
    echo "Create partitions on $DISK by $PARTTOOL in MBR style ..."
    
    if [ "$PARTTOOL" = "parted" ]; then
        vtdebug "format disk by parted ..."
        parted -a none --script $DISK \
            mklabel msdos \
            unit s \
            mkpart primary ntfs $part1_start_sector $part1_end_sector \
            mkpart primary fat16 $part2_start_sector $part2_end_sector \
            set 1 boot on \
            quit

        sync
        echo -en '\xEF' | dd of=$DISK conv=fsync bs=1 count=1 seek=466 > /dev/null 2>&1
    else
    vtdebug "format disk by fdisk ..."
    
fdisk $DISK >>./log.txt 2>&1 <<EOF
o
n
p
1
$part1_start_sector
$part1_end_sector
n
p
2
$part2_start_sector
$part2_end_sector
t
1
7
t
2
ef
a
1
w
EOF
    fi
   
    udevadm trigger --name-match=$DISK >/dev/null 2>&1
    partprobe >/dev/null 2>&1
    partx -u $DISK >/dev/null 2>&1
    sleep 3
    echo "Done"


    echo 'Wait for partitions ...'
    for i in 0 1 2 3 4 5 6 7 8 9; do
        if [ -b $PART1 -a -b $PART2 ]; then
            break
        else
            echo "Wait for $PART1/$PART2 ..."
            sleep 1
        fi
    done

    if ! [ -b $PART1 ]; then
        MajorMinor=$(sed "s/:/ /" /sys/class/block/${PART1#/dev/}/dev)        
        echo "mknod -m 0660 $PART1 b $MajorMinor ..."
        mknod -m 0660 $PART1 b $MajorMinor
    fi
    
    if ! [ -b $PART2 ]; then
        MajorMinor=$(sed "s/:/ /" /sys/class/block/${PART2#/dev/}/dev)        
        echo "mknod -m 0660 $PART2 b $MajorMinor ..."
        mknod -m 0660 $PART2 b $MajorMinor        
    fi

    if [ -b $PART1 -a -b $PART2 ]; then
        echo "partition exist OK"
    else
        echo "[FAIL] $PART1/$PART2 does not exist"
        exit 1
    fi

    echo "create efi fat fs $PART2 ..."
    for i in 0 1 2 3 4 5 6 7 8 9; do
        check_umount_disk "$PART2"

        if mkfs.vfat -F 16 -n VTOYEFI -s 1 $PART2; then
            echo 'success'
            break
        else
            echo "$? retry ..."
            sleep 2
        fi
    done
}


format_ventoy_disk_gpt() {
    reserve_mb=$1
    DISK=$2
    PARTTOOL=$3
    
    PART1=$(get_disk_part_name $DISK 1)
    PART2=$(get_disk_part_name $DISK 2)
    
    sector_num=$(cat /sys/block/${DISK#/dev/}/size)
    
    part1_start_sector=2048 
    
    if [ $reserve_mb -gt 0 ]; then
        reserve_sector_num=$(expr $reserve_mb \* 2048 + 33)
        part1_end_sector=$(expr $sector_num - $reserve_sector_num - $VENTOY_SECTOR_NUM - 1)
    else
        part1_end_sector=$(expr $sector_num - $VENTOY_SECTOR_NUM - 34)
    fi
    
    part2_start_sector=$(expr $part1_end_sector + 1)
    
    modsector=$(expr $part2_start_sector % 8)
    if [ $modsector -gt 0 ]; then
        vtdebug "modsector:$modsector need to be aligned with 4KB"
        part1_end_sector=$(expr $part1_end_sector - $modsector)
        part2_start_sector=$(expr $part1_end_sector + 1)
    fi
    
    part2_end_sector=$(expr $part2_start_sector + $VENTOY_SECTOR_NUM - 1)

    export part2_start_sector

    vtdebug "part1_start_sector=$part1_start_sector  part1_end_sector=$part1_end_sector"
    vtdebug "part2_start_sector=$part2_start_sector  part2_end_sector=$part2_end_sector"

    if [ -e $PART1 ]; then
        echo "delete $PART1"
        rm -f $PART1
    fi

    if [ -e $PART2 ]; then
        echo "delete $PART2"
        rm -f $PART2
    fi

    echo ""
    echo "Create partitions on $DISK by $PARTTOOL in GPT style ..."
    
    vtdebug "format disk by parted ..."
    
    if [ "$TOOLDIR" != "aarch64" ]; then
        vt_set_efi_type="set 2 msftdata on"
    fi    
    
    parted -a none --script $DISK \
        mklabel gpt \
        unit s \
        mkpart Ventoy ntfs $part1_start_sector $part1_end_sector \
        mkpart VTOYEFI fat16 $part2_start_sector $part2_end_sector \
        $vt_set_efi_type \
        quit

    sync
    
    vtoycli gpt -f $DISK
    sync

    udevadm trigger --name-match=$DISK >/dev/null 2>&1
    partprobe >/dev/null 2>&1
    partx -u $DISK >/dev/null 2>&1
    sleep 3
    echo "Done"

    echo 'Wait for partitions ...'
    for i in 0 1 2 3 4 5 6 7 8 9; do
        if [ -b $PART1 -a -b $PART2 ]; then
            break
        else
            echo "Wait for $PART1/$PART2 ..."
            sleep 1
        fi
    done

    if ! [ -b $PART1 ]; then
        MajorMinor=$(sed "s/:/ /" /sys/class/block/${PART1#/dev/}/dev)        
        echo "mknod -m 0660 $PART1 b $MajorMinor ..."
        mknod -m 0660 $PART1 b $MajorMinor
    fi
    
    if ! [ -b $PART2 ]; then
        MajorMinor=$(sed "s/:/ /" /sys/class/block/${PART2#/dev/}/dev)        
        echo "mknod -m 0660 $PART2 b $MajorMinor ..."
        mknod -m 0660 $PART2 b $MajorMinor        
    fi

    if [ -b $PART1 -a -b $PART2 ]; then
        echo "partition exist OK"
    else
        echo "[FAIL] $PART1/$PART2 does not exist"
        exit 1
    fi

    echo "create efi fat fs $PART2 ..."
    
    for i in 0 1 2 3 4 5 6 7 8 9; do
        check_umount_disk "$PART2"
        
        if mkfs.vfat -F 16 -n VTOYEFI -s 1 $PART2; then
            echo 'success'
            break
        else
            echo "$? retry ..."
            sleep 2
        fi
    done
}





