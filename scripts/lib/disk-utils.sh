#!/usr/bin/env bash
# scripts/lib/disk-utils.sh
# 磁盘操作辅助：losetup / 分区识别 / 挂载 / 卸载。
# 配合 lib/common.sh 使用，所有失败均 die。

# 注意：依赖 common.sh 中的 log_* / die / register_cleanup

# ---------- losetup ----------

# attach_loop <image>  -> echo loop 设备路径（含 -P 自动建分区设备节点）
attach_loop() {
  local img="$1"
  [ -f "$img" ] || die "镜像不存在: $img"

  local loop
  loop=$(losetup --show -fP "$img")
  [ -n "$loop" ] || die "losetup 失败: $img"

  # 等待 partprobe 创建分区节点
  udevadm settle 2>/dev/null || true
  sleep 1

  echo "$loop"
}

detach_loop() {
  local loop="$1"
  [ -n "$loop" ] || return 0
  losetup -d "$loop" 2>/dev/null || true
}

# ---------- 分区识别 ----------

# 找到第一个文件系统类型在白名单中的分区。
# find_root_partition <loop_dev> [fstype1 fstype2 ...]
# 默认白名单：ext4 btrfs xfs
find_root_partition() {
  local loop="$1"; shift
  local types=("$@")
  [ ${#types[@]} -eq 0 ] && types=(ext4 btrfs xfs)

  local part fstype t
  for part in "${loop}"p*; do
    [ -b "$part" ] || continue
    fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "")
    for t in "${types[@]}"; do
      if [ "$fstype" = "$t" ]; then
        echo "$part"
        return 0
      fi
    done
  done
  return 1
}

# 找到第一个 vfat 类型的分区（ESP）。
find_esp_partition() {
  local loop="$1"
  local part fstype
  for part in "${loop}"p*; do
    [ -b "$part" ] || continue
    fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "")
    if [ "$fstype" = "vfat" ]; then
      echo "$part"
      return 0
    fi
  done
  return 1
}

# 从分区设备路径提取末尾数字编号（${loop}p2 -> 2）
partition_number() {
  local part="$1"
  echo "$part" | grep -oE 'p[0-9]+$' | tr -d 'p'
}

# ---------- 挂载 ----------

# bind_chroot_fs <rootfs>  绑定 proc/sys/dev/run，并注册自动卸载
bind_chroot_fs() {
  local rootfs="$1"
  local fs
  for fs in proc sys dev run; do
    mkdir -p "$rootfs/$fs"
    mount --bind "/$fs" "$rootfs/$fs"
    register_cleanup "umount -lf '$rootfs/$fs' 2>/dev/null || true"
  done
}

# safe_umount <path>  尝试 umount，失败则 lazy umount
safe_umount() {
  local path="$1"
  [ -n "$path" ] || return 0
  if mountpoint -q "$path" 2>/dev/null; then
    umount "$path" 2>/dev/null || umount -lf "$path" 2>/dev/null || true
  fi
}
