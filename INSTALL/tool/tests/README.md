# Disk safety regression tests

Run on Linux with a POSIX shell:

```sh
sh INSTALL/tool/tests/test_disk_safety.sh
```

The test uses synthetic sysfs, mountinfo and swaps fixtures. It does not create, format, mount, unmount or write to real block devices.

Coverage:
- partition and device-mapper dependency discovery;
- exact major:minor matching (no `/dev/sda` vs `/dev/sdaa` prefix collision);
- active NVMe partition swap;
- mounted device-mapper holder;
- swap-file backing filesystem;
- exact partition unmount selection.

The installer fails closed if it cannot inspect the device graph, mount table, active swap devices or swap-file backing filesystem. Real-hardware testing across SATA, NVMe, MMC, LVM, dm-crypt and MD RAID remains required before proposing this change upstream.
