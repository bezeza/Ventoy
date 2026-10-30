#!/bin/sh
# Synthetic sysfs/proc fixtures: no real block devices are accessed.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
SYS="$TMP/sys/class/block"
DEV="$TMP/sys/devices/block"
BIN="$TMP/bin"
mkdir -p "$SYS" "$DEV" "$BIN"

make_device() {
    name=$1 devno=$2 path="$DEV/$1"
    mkdir -p "$path"
    printf '%s\n' "$devno" > "$path/dev"
    ln -s "$path" "$SYS/$name"
}
make_partition() {
    parent=$1 name=$2 devno=$3 path="$DEV/$1/$2"
    mkdir -p "$path"
    printf '%s\n' "$devno" > "$path/dev"
    printf '1\n' > "$path/partition"
    ln -s "$path" "$SYS/$name"
}
make_device sda 8:0
make_partition sda sda1 8:1
make_device sdaa 8:16
make_partition sdaa sdaa1 8:17
make_device dm-0 253:0
mkdir -p "$DEV/sda/sda1/holders" "$DEV/dm-0/slaves"
ln -s "$SYS/dm-0" "$DEV/sda/sda1/holders/dm-0"
ln -s "$SYS/sda1" "$DEV/dm-0/slaves/sda1"
make_device nvme0n1 259:0
make_partition nvme0n1 nvme0n1p2 259:2

: > "$TMP/mountinfo"
printf 'Filename Type Size Used Priority\n' > "$TMP/swaps"
cat > "$BIN/umount" <<'UMOUNT'
#!/bin/sh
printf '%s\n' "$*" >> "$UMOUNT_LOG"
UMOUNT
chmod +x "$BIN/umount"
cat > "$BIN/findmnt" <<'FINDMNT'
#!/bin/sh
case "$*" in *"/swapfile"*) echo '8:1' ;; *) exit 1 ;; esac
FINDMNT
chmod +x "$BIN/findmnt"

export VENTOY_SYSFS_ROOT="$SYS"
export VENTOY_PROC_MOUNTINFO="$TMP/mountinfo"
export VENTOY_PROC_SWAPS="$TMP/swaps"
export UMOUNT_LOG="$TMP/umount.log"
export PATH="$BIN:$PATH"
. "$ROOT/../../tool/ventoy_lib.sh"
vterr() { printf 'ERROR: %s\n' "$*" >&2; }
vtdebug() { :; }

related=$(ventoy_get_related_block_devices /dev/sda)
case " $related " in *" sda1 "*) ;; *) echo 'FAIL: partition missing'; exit 1;; esac
case " $related " in *" dm-0 "*) ;; *) echo 'FAIL: holder missing'; exit 1;; esac
echo 'PASS: partition and device-mapper dependency discovery'

cat > "$TMP/mountinfo" <<'MOUNTINFO'
36 25 8:17 / /media/sdaa rw,relatime - ext4 /dev/sdaa1 rw
MOUNTINFO
if ventoy_check_disk_busy /dev/sda; then echo 'PASS: no prefix collision'; else exit 1; fi

cat > "$TMP/swaps" <<'SWAPS'
Filename Type Size Used Priority
/dev/nvme0n1p2 partition 1024 0 -2
SWAPS
if ventoy_check_disk_busy /dev/nvme0n1; then echo 'FAIL: NVMe swap missed'; exit 1; else echo 'PASS: NVMe swap detected'; fi

cat > "$TMP/swaps" <<'SWAPS'
Filename Type Size Used Priority
SWAPS
cat > "$TMP/mountinfo" <<'MOUNTINFO'
36 25 253:0 / /var/lib/example rw,relatime - ext4 /dev/dm-0 rw
MOUNTINFO
if ventoy_check_disk_busy /dev/sda; then echo 'FAIL: dm mount missed'; exit 1; else echo 'PASS: device-mapper mount detected'; fi

: > "$TMP/mountinfo"
cat > "$TMP/swaps" <<'SWAPS'
Filename Type Size Used Priority
/swapfile file 1024 0 -2
SWAPS
if ventoy_check_disk_busy /dev/sda; then echo 'FAIL: swapfile missed'; exit 1; else echo 'PASS: swapfile backing device detected'; fi

: > "$TMP/umount.log"
cat > "$TMP/mountinfo" <<'MOUNTINFO'
36 25 8:17 / /media/sdaa rw,relatime - ext4 /dev/sdaa1 rw
MOUNTINFO
check_umount_disk /dev/sda
if [ -s "$TMP/umount.log" ]; then echo 'FAIL: sibling device unmounted'; exit 1; else echo 'PASS: no prefix-based unmount'; fi

cat > "$TMP/mountinfo" <<'MOUNTINFO'
36 25 8:1 / /media/usb rw,relatime - exfat /dev/sda1 rw
MOUNTINFO
check_umount_disk /dev/sda
grep -q '^/media/usb$' "$TMP/umount.log"
echo 'PASS: exact child partition unmount'
echo 'All disk safety tests passed.'
