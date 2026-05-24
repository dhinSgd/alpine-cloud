# 故障排查

## 构建阶段

### 00-prepare：下载失败

```
ERROR: 下载镜像失败 / SHA512 不匹配
```

**原因**：

- CDN 临时不可达
- Alpine 已发布新版本，旧版本被移除
- 网络代理拦截

**对策**：

1. 直接访问 `https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/` 看版本是否还在
2. 如已删除，把 `config/source.env` 中的 `ALPINE_VERSION` 升级到当前可用版本
3. 自行下载 `.qcow2` 与 `.sha512` 放到 `build/source/` 然后跳过 prepare

### 01-extract：识别不到根分区

```
ERROR: 未识别到根分区（ext4/btrfs/xfs）
```

**原因**：Alpine 修改了官方镜像的分区布局或文件系统类型。

**排查**：

```bash
LOOP=$(sudo losetup --show -fP build/source/source-uefi.raw)
sudo lsblk -no NAME,SIZE,FSTYPE "$LOOP"
sudo losetup -d "$LOOP"
```

如果根分区是其它格式（如 squashfs），需要在 `lib/disk-utils.sh` 的 `find_root_partition` 中扩充类型白名单。

### 02-customize：apk 安装失败

```
ERROR: apk add 失败
```

**原因**：

- chroot 内 DNS 不通
- apk 仓库地址在 chroot 内不可达

**对策**：

```bash
# 确认 resolv.conf 已复制
ls -l build/rootfs-uefi/etc/resolv.conf

# 进 chroot 手动测试
sudo chroot build/rootfs-uefi /bin/sh
ping -c 2 8.8.8.8
apk update
exit
```

### 02-customize：内核模块路径不存在

```
WARN: 模块路径不存在（跳过）: drivers/xxx
```

**原因**：Alpine 不同版本内核模块布局不同。

**对策**：跳过即可（警告而非错误）。修订 `config/kernel-modules-remove.list` 删除无意义条目。

### 03-build-image：mkfs.btrfs 不识别参数

```
mkfs.btrfs: unknown option '-M'
```

**原因**：宿主机的 btrfs-progs 版本较旧。

**对策**：升级到 btrfs-progs ≥ 5.x（Ubuntu 22.04 即可）。GitHub Actions runner `ubuntu-24.04` 默认满足。

### 03-build-image：grub.cfg 中找不到旧 UUID

```
WARN: 未在源 rootfs grub.cfg 中找到 root=UUID=...
```

**原因**：Alpine 用 `LABEL` 或 `PARTUUID` 替代了 UUID。

**对策**：

```bash
# 看实际内容
sudo cat build/rootfs-uefi/boot/grub/grub.cfg | grep -E 'root='
```

如果是 `root=LABEL=...`，则改用 `mkfs.btrfs -L "<原label>"` 保留 label 即可（脚本默认是 `slim_alpine_root`，可能与官方 label 不同）。

### 04-finalize：格式自检失败

```
❌ 格式自检失败:
  - compat 异常: '1.1', 期望 '1.1' 或 '0.10'
```

**原因**：qemu-img 版本异常输出。

**对策**：检查 `qemu-img --version`，应 ≥ 6.0。

### 05-test-boot：超时未出现 login

**可能原因**：

1. **GRUB 找不到 root 设备**：UUID 替换错误
2. **initrd 缺失驱动**：删了关键内核模块
3. **rootfstype 错误**：grub.cfg 仍是 `rootfstype=ext4`

**排查**：

```bash
# 本地用图形化 qemu 看错误
qemu-system-x86_64 \
  -m 1024 -smp 2 \
  -drive file=output/slim-alpine-3.23.4-uefi.qcow2,format=qcow2,if=virtio \
  -bios /usr/share/OVMF/OVMF_CODE.fd \
  -enable-kvm
```

观察 GRUB 菜单 → 按 `e` 编辑命令行 → 看 `root=...` 是不是新 UUID、`rootfstype=` 是不是 `btrfs`。

```bash
# 离线挂载验证
sudo guestfish --rw -a output/slim-alpine-3.23.4-uefi.qcow2 -i
><fs> cat /boot/grub/grub.cfg
><fs> cat /etc/fstab
```

## 部署阶段（阿里云）

### 镜像导入失败：「格式不支持」

**原因**：qcow2 内部启用了 `extended-l2` / `compression-type` / `encrypt` 等阿里云未支持的特性。

**对策**：本项目 `04-finalize.sh` 已严格自检，若仍触发请贴出 `qemu-img info` 输出。

### 实例无法启动

**对策**：

1. 在控制台**远程连接**（VNC）查看启动日志
2. 确认实例规格的**启动模式与镜像匹配**（UEFI 镜像不能用在仅支持 BIOS 的规格上）
3. 临时挂载镜像盘到另一台正常实例做离线诊断

### cloud-init 没有自动扩容

**对策**：

```bash
# 手动扩容
ROOTDEV=$(findmnt -n -o SOURCE /)
DISK=$(lsblk -no PKNAME "$ROOTDEV")
growpart "/dev/$DISK" "$(echo "$ROOTDEV" | grep -oE '[0-9]+$')"
btrfs filesystem resize max /
```

并排查 cloud-init 日志：

```bash
cat /var/log/cloud-init.log
cat /var/log/cloud-init-output.log
```

### 时间不同步

```bash
service chronyd status
service chronyd restart
chronyc sources
```

如要换用阿里云 NTP：

```bash
echo "server ntp.aliyun.com iburst" > /etc/chrony/chrony.conf
service chronyd restart
```

### SSH 拒绝连接

- 检查安全组是否开放 22 端口
- 检查 `/etc/ssh/sshd_config` 是否 `PermitRootLogin yes`
- 用 VNC 重启 sshd：`service sshd restart`

### btrfs 报错 "No space left on device" 但 `df` 显示有空间

这是 btrfs 元数据耗尽的典型现象。

```bash
btrfs filesystem balance start -m / 2>/dev/null
btrfs filesystem balance start -dusage=50 / 2>/dev/null
```

## 仍然解决不了

提 Issue 时请附上：

- 触发的阶段（`00`~`05`）
- 完整的 stderr 输出
- `config/source.env` 中的 `ALPINE_VERSION`
- 宿主机 `qemu-img --version` 和 `btrfs --version`
