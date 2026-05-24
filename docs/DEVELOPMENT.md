# 开发文档

## 本地构建环境要求

| 组件 | 说明 |
|------|------|
| OS | Ubuntu 22.04 / 24.04 或 Debian 12+（其它发行版需自行安装依赖） |
| 权限 | 全程需要 root（脚本内部多处 `mount`/`losetup`/`chroot`） |
| 磁盘 | 至少 4GB 空闲（中间 raw 镜像 + rootfs + 输出） |
| 网络 | 能访问 `dl-cdn.alpinelinux.org`；apk add 需要 chroot 内联网 |

## 一键完整构建

```bash
# 同时构建 UEFI + BIOS
for BOOT in uefi bios; do
  sudo bash scripts/00-prepare.sh     --boot "$BOOT"
  sudo bash scripts/01-extract.sh     --boot "$BOOT"
  sudo bash scripts/02-customize.sh   --boot "$BOOT"
  sudo bash scripts/03-build-image.sh --boot "$BOOT"
  sudo bash scripts/04-finalize.sh    --boot "$BOOT"
  sudo bash scripts/05-test-boot.sh   --boot "$BOOT" --timeout 180
done
```

产物在 `output/`：

```
output/
├── slim-alpine-3.23.4-uefi.qcow2
├── slim-alpine-3.23.4-uefi.qcow2.sha256
├── slim-alpine-3.23.4-bios.qcow2
└── slim-alpine-3.23.4-bios.qcow2.sha256
```

## 阶段说明

| 阶段 | 脚本 | 大致耗时 | 关键操作 |
|------|------|----------|----------|
| 0 | `00-prepare.sh` | 1-2 min | 安装依赖 + 下载官方镜像 + sha512 校验 |
| 1 | `01-extract.sh` | 30s | qcow2 → raw → 挂载 → rsync rootfs |
| 2 | `02-customize.sh` | 1-2 min | chroot 安装/裁剪/配置 |
| 3 | `03-build-image.sh` | 1 min | 创建 btrfs 镜像、复制引导、rsync |
| 4 | `04-finalize.sh` | 30s | qcow2 转换 + 严格自检 |
| 5 | `05-test-boot.sh` | 1-2 min | qemu 启动测试 |

## 修改配置

所有可调项集中在 `config/`：

| 文件 | 作用 |
|------|------|
| `source.env` | Alpine 版本、URL、btrfs 参数、默认密码 |
| `packages-install.list` | 镜像内置工具白名单 |
| `packages-remove.list` | 卸载包黑名单（第一版为空） |
| `kernel-modules-blacklist.conf` | modprobe.d 黑名单（软兜底） |
| `kernel-modules-remove.list` | 实际删除模块目录列表 |
| `cloud-init-aliyun.cfg` | cloud-init Aliyun 优先配置 |

修改后只需重跑相关阶段，例如调整内核模块清单后：

```bash
# 重新跑 customize 起的阶段
sudo bash scripts/02-customize.sh   --boot uefi
sudo bash scripts/03-build-image.sh --boot uefi
sudo bash scripts/04-finalize.sh    --boot uefi
```

> 注意：`01-extract` 提取的 rootfs 在 `customize` 阶段被原地修改，所以重跑前需要先重新跑 `01-extract.sh`，或备份原始 rootfs。

## 升级 Alpine 版本

编辑 `config/source.env`：

```bash
ALPINE_VERSION="3.24.0"
ALPINE_MAJOR_MINOR="3.24"
```

SHA512 自动从 Alpine 官方 `.sha512` 文件下载，无需手动更新。

## 调试技巧

### 进入 chroot 手动调试

```bash
# 假设已经跑过 01-extract.sh
ROOTFS=build/rootfs-uefi
sudo mount --bind /proc "$ROOTFS/proc"
sudo mount --bind /sys  "$ROOTFS/sys"
sudo mount --bind /dev  "$ROOTFS/dev"
sudo mount --bind /run  "$ROOTFS/run"
sudo cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

sudo chroot "$ROOTFS" /bin/sh

# 调试完毕
exit
for fs in run dev sys proc; do sudo umount -lf "$ROOTFS/$fs"; done
```

### 检查阶段产物

```bash
# 看 rootfs 体积
du -sh build/rootfs-uefi

# 看目标 raw 镜像分区
fdisk -l build/output-uefi.img

# 看最终 qcow2 信息
qemu-img info output/slim-alpine-*.qcow2
```

### 启动失败定位

```bash
# 去掉 -nographic，本地图形化查看 grub/kernel 错误
qemu-system-x86_64 \
  -m 1024 -smp 2 \
  -drive file=output/slim-alpine-3.23.4-uefi.qcow2,format=qcow2,if=virtio \
  -bios /usr/share/OVMF/OVMF_CODE.fd \
  -enable-kvm
```

### 用 guestfish 离线挂载查看

```bash
sudo guestfish --rw -a output/slim-alpine-3.23.4-uefi.qcow2 -i

><fs> ls /
><fs> cat /etc/fstab
><fs> cat /boot/grub/grub.cfg
```

## CI/CD

`.github/workflows/build.yml` 由 push 到 main/master 自动触发（path 过滤 `scripts/**`、`config/**`、`build.yml`）。

也可手动触发：

GitHub → Actions → Build Slim Alpine Cloud Image → Run workflow，可填写自定义 release tag。

完整流程：

```
build (uefi 并行 bios)
  ↓
test  (uefi 并行 bios)
  ↓
release (合并产物 + GitHub Release)
```

## 代码风格

- bash 全部加 `set -Eeuo pipefail`
- 经过 `shellcheck` 校验
- 路径变量统一加引号
- 失败立刻通过 `die` 退出
- 通过 `register_cleanup` 注册清理钩子，避免遗留 loop 设备
