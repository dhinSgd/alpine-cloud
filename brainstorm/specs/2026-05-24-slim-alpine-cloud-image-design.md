# Slim Alpine Cloud Image 设计文档

**日期**：2026-05-24
**项目名**：alpine-cloud
**目标**：基于 Alpine 官方 cloud 镜像构建精简版云镜像，适配阿里云 ECS

---

## 1. 概述

### 1.1 背景与目标

基于 Alpine Linux 官方 cloud 镜像（带 cloud-init）进行裁剪和优化，生成针对阿里云 ECS 优化的精简镜像。

**核心目标：**
- 体积更小：通过 btrfs zstd:9 透明压缩，减小镜像体积及未来文件占用
- 兼容性好：直接复用 Alpine 官方 cloud-init 镜像的引导配置，避免手动安装 GRUB 的兼容性风险
- 易于维护：通过 GitHub Actions 自动化构建，配置项集中管理
- 阿里云特化：保留 cloud-init 完整功能，专为阿里云 ECS 优化

### 1.2 范围（In Scope）

- 仅适配阿里云 ECS（不考虑其他云平台）
- 仅 x86_64 架构
- 同时支持 UEFI 和 BIOS 启动（生成两个独立镜像）
- 基于 Alpine 3.23.4（可参数化版本号）
- 第一版保守精简：仅删除明确不需要的硬件驱动（蓝牙、声卡、显卡等）

### 1.3 非目标（Out of Scope）

- ❌ 不支持 ARM64 等其他架构（第一版）
- ❌ 不支持其他云平台特化（AWS、GCP、Azure 等）
- ❌ 不发布 RAW、VHD 等其他格式
- ❌ 不内置开发工具链（gcc、make、git 等）
- ❌ 不做容器/Kubernetes 优化
- ❌ 不实现自动版本跟踪、定时构建（push 触发）
- ❌ 不内置加密、SELinux 等高级安全特性

---

## 2. 需求清单

| 类别 | 决策 |
|------|------|
| **基础系统** | Alpine 3.23.4 官方 cloud 镜像 |
| **源镜像** | 同时下载 UEFI 和 BIOS 两个官方镜像 |
| **精简策略** | 黑名单模式（保守删除） |
| **cloud-init** | 完整保留 |
| **内置工具** | ping、wget、curl、nano、chrony |
| **自动扩容** | cloud-init 内置模块（growpart + resizefs） |
| **内核精简** | 删蓝牙/声卡/显卡/无线/媒体/游戏手柄等明确不需要的硬件驱动 |
| **构建触发** | GitHub Actions：push 到主分支自动触发 |
| **发布方式** | GitHub Releases，仅 qcow2 格式 |
| **分区方案** | 沿用官方分区（不修改），仅根分区换为 btrfs |
| **文件系统** | btrfs + zstd:9 压缩 |
| **目标体积** | 1GB 虚拟磁盘（实际 qcow2 文件预估 300-500MB） |
| **引导方式** | 两个独立镜像：纯 UEFI + 纯 BIOS（不要双引导） |
| **默认账户** | root / slimalpine123（含安全提示） |
| **仓库结构** | 模块化（scripts/ + config/ + docs/） |
| **构建方法** | 基于官方镜像修改 + 重新打包为 btrfs |
| **qcow2 转换** | `qemu-img convert -p -O qcow2`（v3 默认，不压缩，最大兼容性） |

---

## 3. 整体架构

### 3.1 构建流程图

```
┌───────────────────────────────────────────────────────────────┐
│                  GitHub Actions Workflow                       │
│              (push 到主分支自动触发)                            │
└──────────────────────────────┬────────────────────────────────┘
                               │
                               ▼
               ┌───────────────────────────────┐
               │ matrix: [uefi, bios] 并行构建  │
               └───────────────┬───────────────┘
                               │
        ┌──────────────────────┴──────────────────────┐
        ▼                                             ▼
┌───────────────┐                              ┌───────────────┐
│   UEFI 分支    │                              │   BIOS 分支    │
└───────┬───────┘                              └───────┬───────┘
        │                                              │
        ▼                                              ▼
┌─────────────────────────────────────────────────────────────┐
│ 阶段 0: prepare.sh                                            │
│   - 安装构建依赖                                              │
│   - 下载对应官方镜像                                          │
│     (uefi.qcow2 或 bios.qcow2)                              │
├─────────────────────────────────────────────────────────────┤
│ 阶段 1: extract.sh                                            │
│   - qemu-img convert 转 raw                                  │
│   - kpartx/losetup 挂载                                      │
│   - rsync 提取 rootfs 到 build/rootfs-{boot}/               │
│   - 保留原分区表与 ESP 分区信息                                │
├─────────────────────────────────────────────────────────────┤
│ 阶段 2: customize.sh ⭐                                       │
│   chroot 环境内：                                            │
│   1. 安装工具 (ping/wget/curl/nano/chrony +                  │
│      cloud-utils-growpart)                                   │
│   2. 卸载黑名单包                                            │
│   3. 删除黑名单内核模块文件                                   │
│   4. depmod -a 重建模块依赖                                  │
│   5. 设置 root 密码                                          │
│   6. 配置 cloud-init（保留完整，添加 Aliyun                   │
│      datasource 优先）                                        │
│   7. 启用 chronyd + sshd + cloud-init 服务                   │
│   8. 清理缓存、文档、日志                                     │
├─────────────────────────────────────────────────────────────┤
│ 阶段 3: build-image.sh                                        │
│   1. 创建 1GB 空 qcow2                                       │
│   2. 复制原镜像分区表（保留官方引导配置）                      │
│   3. 复制 ESP 分区（UEFI 版）/ MBR 区域（BIOS 版）            │
│   4. 根分区 mkfs.btrfs（用 longsays 参数）                   │
│   5. 挂载根分区（compress-force=zstd:9）                      │
│   6. 创建 @ 子卷                                             │
│   7. rsync rootfs 到新文件系统                                │
│   8. 更新 /etc/fstab（btrfs + UUID）                         │
│   9. 更新 GRUB 配置中的 root= UUID                            │
├─────────────────────────────────────────────────────────────┤
│ 阶段 4: finalize.sh                                          │
│   1. qemu-img convert -p -O qcow2                            │
│      （v3 默认，不压缩，最大兼容性）                          │
│   2. qemu-img info / check 严格自检                           │
│   3. 生成 SHA256                                             │
│   4. 重命名为 slim-alpine-{ver}-{boot}.qcow2                 │
└─────────────────────────────────────────────────────────────┘
        │                                              │
        └──────────────────────┬──────────────────────┘
                               ▼
               ┌───────────────────────────────┐
               │   test job (matrix 并行)       │
               │   qemu 启动测试 + 串口校验      │
               └───────────────┬───────────────┘
                               ▼
               ┌───────────────────────────────┐
               │   release job                  │
               │   - 合并产物                   │
               │   - 生成 SHA256SUMS            │
               │   - 创建 GitHub Release        │
               └───────────────────────────────┘

产物：
  ├─ slim-alpine-3.23.4-uefi.qcow2  (~300-500MB)
  ├─ slim-alpine-3.23.4-bios.qcow2  (~300-500MB)
  └─ SHA256SUMS
```

### 3.2 关键设计决策与理由

#### 决策 1：基于双源官方镜像（而非单源+手动双引导）

**选择**：分别下载 UEFI 官方镜像和 BIOS 官方镜像，各自精简和打包

**理由**：
- 完全复用官方测试过的引导配置，避免手动安装 GRUB 出错
- 阶段 3 代码大幅简化，不需要 grub-install / grub-mkconfig
- 多下载 50MB 一次性开销，相对工程可靠性收益不值一提

#### 决策 2：使用 btrfs + zstd:9 透明压缩

**选择**：根分区文件系统从 ext4 改为 btrfs，启用最高级 zstd 压缩

**理由**：
- 显著降低实际磁盘占用（预估 50-70% 压缩率）
- 用户后续写入文件自动压缩，长期收益
- Alpine 内核原生支持，零额外配置
- 参考实现 longsays/debian-btrfs 已实战验证

#### 决策 3：qcow2 转换不加 -c 压缩

**选择**：`qemu-img convert -p -O qcow2`（默认参数，v3，不压缩）

**理由**：
- 优先保证阿里云兼容性，避免任何潜在的格式校验问题
- 文件略大可接受（300-500MB vs 100-150MB）
- btrfs 内部已有 zstd 压缩，整体体积仍可控

#### 决策 4：内核精简用黑名单（保守策略）

**选择**：第一版仅删明确不需要的硬件驱动，不确定的一律保留

**理由**：
- 避免过度精简导致云服务器场景下意外问题
- 渐进式优化：后续可基于实测数据增删
- 可维护性高：黑名单清单独立成 config 文件

#### 决策 5：使用 longsays 的 btrfs 参数配置

**选择**：完全采用 `subvol=@,compress-force=zstd:9,discard=async,...` 等参数

**理由**：
- 已经过 longsays/debian-btrfs 项目的实战验证（用户实测可用）
- 各参数都有明确目的（详见第 5.3 节）
- 避免重新调优的时间成本

---

## 4. 仓库目录结构

```
alpine-cloud/
├── .github/
│   └── workflows/
│       └── build.yml                 # GitHub Actions 主工作流
│
├── scripts/                          # 构建脚本（按阶段拆分）
│   ├── 00-prepare.sh                 # 安装依赖、下载官方镜像
│   ├── 01-extract.sh                 # 挂载官方 qcow2，提取 rootfs
│   ├── 02-customize.sh               # chroot 内裁剪与配置
│   ├── 03-build-image.sh             # 创建新 qcow2 + btrfs
│   ├── 04-finalize.sh                # 格式转换、严格自检、SHA256
│   ├── 05-test-boot.sh               # qemu 启动测试
│   └── lib/
│       ├── common.sh                 # 日志、错误处理、清理
│       └── disk-utils.sh             # losetup/kpartx/mount 等磁盘操作
│
├── config/                           # 所有可配置项集中管理
│   ├── source.env                    # 镜像版本、URL、SHA256 期望值
│   ├── packages-install.list         # 要安装的工具
│   ├── packages-remove.list          # 要卸载的包黑名单
│   ├── kernel-modules-blacklist.conf # 内核模块黑名单
│   ├── kernel-modules-remove.list    # 要删除的内核模块目录列表
│   └── cloud-init-aliyun.cfg         # Aliyun datasource 优先配置
│
├── docs/
│   ├── USAGE.md                      # 阿里云部署使用说明
│   ├── DEVELOPMENT.md                # 开发文档（本地构建、调试）
│   └── TROUBLESHOOTING.md            # 故障排查
│
├── brainstorm/
│   └── specs/
│       └── 2026-05-24-slim-alpine-cloud-image-design.md
│
├── .gitignore                        # 忽略 build/ output/
├── LICENSE
└── README.md                         # 项目说明、快速开始
```

**运行时生成的目录（.gitignore）：**
- `build/` — 中间产物（下载的镜像、临时 rootfs、挂载点）
- `output/` — 最终产物（qcow2 + SHA256SUMS）

---

## 5. 各阶段详细设计

### 5.1 阶段 0: prepare.sh

**职责：** 准备构建环境

**关键操作：**
```bash
# 1. 安装依赖（在 GitHub Actions runner 上）
sudo apt-get update
sudo apt-get install -y \
  qemu-utils qemu-system-x86 \
  libguestfs-tools \
  btrfs-progs rsync parted kpartx \
  dosfstools

# 2. 读取 config/source.env 中的镜像 URL
source config/source.env

# 3. 根据 --boot 参数下载对应官方镜像
if [ "$BOOT_TYPE" = "uefi" ]; then
  IMAGE_URL="$UEFI_IMAGE_URL"
  IMAGE_FILE="$UEFI_IMAGE_FILE"
else
  IMAGE_URL="$BIOS_IMAGE_URL"
  IMAGE_FILE="$BIOS_IMAGE_FILE"
fi

# 4. 下载并校验 SHA256
mkdir -p build/source
wget -O "build/source/$IMAGE_FILE" "$IMAGE_URL"
sha256sum -c <(echo "$EXPECTED_SHA256  build/source/$IMAGE_FILE")
```

**config/source.env 内容示例：**
```bash
ALPINE_VERSION="3.23.4"
ALPINE_MAJOR_MINOR="3.23"

UEFI_IMAGE_FILE="generic_alpine-${ALPINE_VERSION}-x86_64-uefi-cloudinit-r0.qcow2"
UEFI_IMAGE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MAJOR_MINOR}/releases/cloud/${UEFI_IMAGE_FILE}"

BIOS_IMAGE_FILE="generic_alpine-${ALPINE_VERSION}-x86_64-bios-cloudinit-r0.qcow2"
BIOS_IMAGE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MAJOR_MINOR}/releases/cloud/${BIOS_IMAGE_FILE}"

# SHA256 校验文件 URL 模式（Alpine 官方对每个文件提供同名 .sha256 文件）
UEFI_IMAGE_SHA256_URL="${UEFI_IMAGE_URL}.sha256"
BIOS_IMAGE_SHA256_URL="${BIOS_IMAGE_URL}.sha256"
```

**SHA256 校验策略：** 不在 source.env 硬编码 SHA256，而是在 `prepare.sh` 中从 Alpine 官方同步下载对应的 `.sha256` 文件进行校验。这样升级 Alpine 版本时只需改 `ALPINE_VERSION`，无需手动查询并更新校验和。

```bash
# prepare.sh 中的实际校验逻辑
wget -O "build/source/${IMAGE_FILE}" "${IMAGE_URL}"
wget -O "build/source/${IMAGE_FILE}.sha256" "${IMAGE_SHA256_URL}"
cd build/source && sha256sum -c "${IMAGE_FILE}.sha256"
```

### 5.2 阶段 1: extract.sh

**职责：** 把官方镜像挂载并提取 rootfs

**关键操作：**
```bash
# 1. 转 qcow2 -> raw（便于 losetup 操作）
qemu-img convert -p -O raw \
  "build/source/$IMAGE_FILE" \
  "build/source/source-${BOOT_TYPE}.raw"

# 2. losetup 挂载为块设备
LOOP_DEV=$(sudo losetup --show -fP "build/source/source-${BOOT_TYPE}.raw")
sleep 1  # 等待内核创建分区设备节点

# 3. 动态识别根分区（不依赖固定的 p1/p2 编号）
#    遍历所有分区，找到文件系统类型为 ext4/btrfs/xfs 的最大分区作为根分区
ROOT_PART=""
for PART in ${LOOP_DEV}p*; do
  FSTYPE=$(sudo blkid -s TYPE -o value "$PART" 2>/dev/null || echo "")
  case "$FSTYPE" in
    ext4|btrfs|xfs)
      ROOT_PART="$PART"
      break
      ;;
  esac
done
[ -z "$ROOT_PART" ] && { echo "❌ 未找到根分区"; exit 1; }
echo "识别到根分区: $ROOT_PART (类型: $FSTYPE)"

# 4. 挂载根分区
sudo mkdir -p build/mnt-${BOOT_TYPE}
sudo mount "$ROOT_PART" build/mnt-${BOOT_TYPE}

# 5. rsync 提取 rootfs
sudo rsync -aHAX --numeric-ids \
  build/mnt-${BOOT_TYPE}/ \
  build/rootfs-${BOOT_TYPE}/

# 6. 保存分区表信息（供阶段 3 使用）
sudo sfdisk -d "$LOOP_DEV" > "build/source/partition-${BOOT_TYPE}.dump"

# 6b. 记录根分区编号到辅助文件（供阶段 3 使用）
ROOT_PART_NUM=$(echo "$ROOT_PART" | grep -oE 'p[0-9]+$' | tr -d 'p')
echo "$ROOT_PART_NUM" > "build/source/root-partnum-${BOOT_TYPE}.txt"

# 6c. UEFI 版本：识别并记录 ESP 分区编号
if [ "$BOOT_TYPE" = "uefi" ]; then
  for PART in ${LOOP_DEV}p*; do
    FSTYPE=$(sudo blkid -s TYPE -o value "$PART" 2>/dev/null || echo "")
    if [ "$FSTYPE" = "vfat" ]; then
      ESP_PART_NUM=$(echo "$PART" | grep -oE 'p[0-9]+$' | tr -d 'p')
      echo "$ESP_PART_NUM" > "build/source/esp-partnum-${BOOT_TYPE}.txt"
      break
    fi
  done
fi

# 7. 卸载与清理
sudo umount build/mnt-${BOOT_TYPE}
sudo losetup -d "$LOOP_DEV"
```

**关于分区布局的说明：**
- Alpine UEFI 镜像（实测）：p1=ESP (FAT32), p2=root (ext4)
- Alpine BIOS 镜像（实测）：p1=root (ext4)
- 但脚本不依赖固定编号，而是通过 blkid 动态识别根分区，对未来官方调整布局更鲁棒

**为什么先提取出来？**
- 后续 chroot 操作在解耦的目录上更可控
- 失败可重试，不污染源镜像
- 便于本地调试

### 5.3 阶段 2: customize.sh（核心精简逻辑）⭐

**职责：** chroot 内完成所有精简和定制

**关键操作（按顺序）：**

#### 5.3.1 准备 chroot 环境

```bash
ROOTFS="build/rootfs-${BOOT_TYPE}"

# 挂载虚拟文件系统
for fs in proc sys dev run; do
  sudo mount --bind "/$fs" "$ROOTFS/$fs"
done

# 让 chroot 能联网（用于 apk add）
sudo cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
```

#### 5.3.2 更新 apk 索引并安装工具

```bash
sudo chroot "$ROOTFS" apk update

# 读取 config/packages-install.list
INSTALL_PACKAGES=$(grep -v '^#' config/packages-install.list | tr '\n' ' ')
sudo chroot "$ROOTFS" apk add --no-cache $INSTALL_PACKAGES
```

**config/packages-install.list 内容：**
```
# 网络工具
iputils       # ping
wget
curl

# 编辑器
nano

# 时间同步
chrony

# 云镜像自动扩容必需
cloud-utils-growpart
```

#### 5.3.3 卸载不需要的软件包

```bash
REMOVE_PACKAGES=$(grep -v '^#' config/packages-remove.list | tr '\n' ' ')
sudo chroot "$ROOTFS" apk del $REMOVE_PACKAGES || true
```

**config/packages-remove.list 内容（第一版保守）：**
```
# 文档（apk 默认就不装大量文档，这里仅清残留）
# man-pages
# docs

# 第一版暂不卸载任何包，仅做内核模块裁剪
# 后续可根据实际镜像分析增加
```

#### 5.3.4 内核模块精简（核心精简）⭐

```bash
KERNEL_VERSION=$(ls "$ROOTFS/lib/modules/" | head -1)
MODULES_DIR="$ROOTFS/lib/modules/$KERNEL_VERSION/kernel"

# 第一步：写入 modprobe.d 黑名单（保险措施）
sudo cp config/kernel-modules-blacklist.conf \
  "$ROOTFS/etc/modprobe.d/blacklist-slim.conf"

# 第二步：实际删除模块文件（真正减小磁盘占用）
while IFS= read -r MODULE_PATH; do
  # 跳过注释和空行
  [[ "$MODULE_PATH" =~ ^# ]] && continue
  [[ -z "$MODULE_PATH" ]] && continue

  TARGET="$MODULES_DIR/$MODULE_PATH"
  if [ -d "$TARGET" ] || [ -f "$TARGET" ]; then
    echo "删除: $MODULE_PATH"
    sudo rm -rf "$TARGET"
  fi
done < config/kernel-modules-remove.list

# 第三步：重新生成 modules.dep
sudo chroot "$ROOTFS" depmod -a "$KERNEL_VERSION"
```

**config/kernel-modules-blacklist.conf 内容：**
```
# 蓝牙
blacklist bluetooth
blacklist btusb
blacklist btrtl
blacklist btintel
blacklist btbcm

# 声卡
blacklist snd
blacklist snd_pcm
blacklist snd_timer
blacklist soundcore

# 显卡
blacklist drm
blacklist drm_kms_helper

# 无线网卡
blacklist cfg80211
blacklist mac80211

# 摄像头
blacklist videodev
blacklist videobuf2_common

# 游戏手柄
blacklist joydev
```

**config/kernel-modules-remove.list 内容：**
```
# 这是要从磁盘上实际删除的模块目录路径
# 路径相对于 /lib/modules/<version>/kernel/

# 蓝牙
drivers/bluetooth
net/bluetooth

# 声卡
sound

# 显卡（保留基础 framebuffer，删高级 GPU 驱动）
drivers/gpu/drm
# 注意：保留 drivers/video（fbcon 等基础显示）

# 无线网卡
drivers/net/wireless
net/wireless
net/mac80211

# 摄像头/电视卡
drivers/media

# 游戏手柄
drivers/input/joystick
drivers/input/gameport

# USB 音视频设备
drivers/usb/serial
drivers/usb/musb
drivers/usb/atm

# 红外线
drivers/media/rc

# 触摸屏
drivers/input/touchscreen

# 平板专用
drivers/input/tablet
```

#### 5.3.5 配置 root 密码

```bash
sudo chroot "$ROOTFS" sh -c 'echo "root:slimalpine123" | chpasswd'

# 允许 root 通过密码 SSH 登录
sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' \
  "$ROOTFS/etc/ssh/sshd_config"
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' \
  "$ROOTFS/etc/ssh/sshd_config"
```

#### 5.3.6 配置 cloud-init（保留完整，添加 Aliyun 优先）

```bash
sudo cp config/cloud-init-aliyun.cfg \
  "$ROOTFS/etc/cloud/cloud.cfg.d/90-aliyun.cfg"
```

**config/cloud-init-aliyun.cfg 内容：**
```yaml
# 优先使用阿里云元数据服务
datasource_list: [AliYun, NoCloud, ConfigDrive, None]

datasource:
  AliYun:
    timeout: 5
    max_wait: 10

# 启用关键模块（确认默认启用）
cloud_init_modules:
  - migrator
  - seed_random
  - bootcmd
  - write-files
  - growpart           # 自动扩容分区
  - resizefs           # 自动扩容文件系统
  - disk_setup
  - mounts
  - set_hostname
  - update_hostname
  - update_etc_hosts
  - ca-certs
  - rsyslog
  - users-groups
  - ssh
```

#### 5.3.7 启用服务

```bash
sudo chroot "$ROOTFS" rc-update add chronyd default
sudo chroot "$ROOTFS" rc-update add sshd default
sudo chroot "$ROOTFS" rc-update add cloud-init-local boot
sudo chroot "$ROOTFS" rc-update add cloud-init default
sudo chroot "$ROOTFS" rc-update add cloud-config default
sudo chroot "$ROOTFS" rc-update add cloud-final default
```

#### 5.3.8 清理

```bash
# 清理 apk 缓存
sudo rm -rf "$ROOTFS/var/cache/apk/"*

# 清理临时文件
sudo rm -rf "$ROOTFS/tmp/"* "$ROOTFS/var/tmp/"*

# 清理日志
sudo rm -rf "$ROOTFS/var/log/"*

# 清理文档
sudo rm -rf "$ROOTFS/usr/share/doc/"*
sudo rm -rf "$ROOTFS/usr/share/man/"*
sudo rm -rf "$ROOTFS/usr/share/info/"*

# 清理本地化（保留 en, zh）
find "$ROOTFS/usr/share/locale/" -mindepth 1 -maxdepth 1 \
  ! -name 'en*' ! -name 'zh*' -exec sudo rm -rf {} + 2>/dev/null || true

# 清理 machine-id（让 cloud-init 首次启动重新生成）
sudo truncate -s 0 "$ROOTFS/etc/machine-id"
sudo rm -f "$ROOTFS/var/lib/dbus/machine-id"

# 清理 SSH host keys（让首次启动重新生成）
sudo rm -f "$ROOTFS/etc/ssh/ssh_host_"*

# 卸载 chroot 环境
sudo rm -f "$ROOTFS/etc/resolv.conf"
for fs in run dev sys proc; do
  sudo umount "$ROOTFS/$fs"
done
```

### 5.4 阶段 3: build-image.sh

**职责：** 创建新 qcow2，转 btrfs，复制 rootfs

**关键操作：**

```bash
OUTPUT_IMG="build/output-${BOOT_TYPE}.img"
ROOTFS="build/rootfs-${BOOT_TYPE}"
MOUNT_DIR="build/mnt-new-${BOOT_TYPE}"

# 读取阶段 1 记录的分区编号
ROOT_PART_NUM=$(cat "build/source/root-partnum-${BOOT_TYPE}.txt")

# btrfs 参数（抄 longsays）
BTRFS_MOUNT_OPTS="subvol=@,compress-force=zstd:9,discard=async,relatime,max_inline=3796,commit=60,space_cache=v2"
BTRFS_MKFS_OPTS="-f -M -n 4k"

# 1. 创建 1GB 空镜像
sudo fallocate -l 1G "$OUTPUT_IMG"

# 2. 恢复原镜像的分区表（保留官方引导结构）
sudo sfdisk "$OUTPUT_IMG" < "build/source/partition-${BOOT_TYPE}.dump"

# 3. losetup 挂载
LOOP_DEV=$(sudo losetup --show -fP "$OUTPUT_IMG")
sleep 1

# 4. UEFI 版本：复制 ESP 分区内容
if [ "$BOOT_TYPE" = "uefi" ]; then
  ESP_PART_NUM=$(cat "build/source/esp-partnum-${BOOT_TYPE}.txt")
  ORIG_LOOP=$(sudo losetup --show -fP \
    "build/source/source-${BOOT_TYPE}.raw")
  sleep 1
  sudo dd if="${ORIG_LOOP}p${ESP_PART_NUM}" \
    of="${LOOP_DEV}p${ESP_PART_NUM}" bs=1M
  sudo losetup -d "$ORIG_LOOP"
fi

# 5. BIOS 版本：复制 MBR 引导代码（前 446 字节）
if [ "$BOOT_TYPE" = "bios" ]; then
  ORIG_LOOP=$(sudo losetup --show -fP \
    "build/source/source-${BOOT_TYPE}.raw")
  sudo dd if="$ORIG_LOOP" of="$LOOP_DEV" bs=446 count=1 conv=notrunc
  sudo losetup -d "$ORIG_LOOP"
fi

# 6. 根分区格式化为 btrfs
ROOT_PART="${LOOP_DEV}p${ROOT_PART_NUM}"
sudo mkfs.btrfs $BTRFS_MKFS_OPTS -L "slim_alpine_root" "$ROOT_PART"

# 7. 挂载根分区并创建 @ 子卷
sudo mkdir -p "$MOUNT_DIR"
# 先用基础选项挂载创建 @ 子卷
sudo mount "$ROOT_PART" "$MOUNT_DIR"
sudo btrfs subvolume create "$MOUNT_DIR/@"
sudo umount "$MOUNT_DIR"

# 8. 用 subvol=@ 挂载并 rsync rootfs
sudo mount -o "$BTRFS_MOUNT_OPTS" "$ROOT_PART" "$MOUNT_DIR"
sudo rsync -aHAX --numeric-ids --sparse \
  "$ROOTFS/" "$MOUNT_DIR/"

# 9. 更新 /etc/fstab
ROOT_UUID=$(sudo blkid -s UUID -o value "$ROOT_PART")
sudo tee "$MOUNT_DIR/etc/fstab" > /dev/null <<EOF
UUID=$ROOT_UUID / btrfs $BTRFS_MOUNT_OPTS 0 0
EOF

if [ "$BOOT_TYPE" = "uefi" ]; then
  ESP_UUID=$(sudo blkid -s UUID -o value "${LOOP_DEV}p${ESP_PART_NUM}")
  echo "UUID=$ESP_UUID /boot/efi vfat defaults,umask=0077 0 1" | \
    sudo tee -a "$MOUNT_DIR/etc/fstab"
fi

# 10. 更新 GRUB 配置中的 root UUID
# 官方镜像里 GRUB 配置可能引用了旧的 UUID
# 需要 sed 替换为新的 UUID
OLD_ROOT_UUID=$(sudo grep -oE 'root=UUID=[a-f0-9-]+' \
  "$ROOTFS/boot/grub/grub.cfg" | head -1 | cut -d= -f3)
sudo sed -i "s/$OLD_ROOT_UUID/$ROOT_UUID/g" \
  "$MOUNT_DIR/boot/grub/grub.cfg"

# 同时更新内核命令行的 rootfstype（如果有）
sudo sed -i 's/rootfstype=ext4/rootfstype=btrfs/g' \
  "$MOUNT_DIR/boot/grub/grub.cfg"

# UEFI 版本：同时更新 ESP 分区内的 grub.cfg（如果有独立的）
if [ "$BOOT_TYPE" = "uefi" ]; then
  sudo mkdir -p "$MOUNT_DIR/boot/efi"
  sudo mount "${LOOP_DEV}p${ESP_PART_NUM}" "$MOUNT_DIR/boot/efi"
  # 查找 ESP 中所有 grub.cfg 并替换 UUID
  sudo find "$MOUNT_DIR/boot/efi" -name "grub.cfg" -exec \
    sed -i "s/$OLD_ROOT_UUID/$ROOT_UUID/g" {} \;
  sudo find "$MOUNT_DIR/boot/efi" -name "grub.cfg" -exec \
    sed -i 's/rootfstype=ext4/rootfstype=btrfs/g' {} \;
  sudo umount "$MOUNT_DIR/boot/efi"
fi

# 11. 清理
sudo umount "$MOUNT_DIR"
sudo losetup -d "$LOOP_DEV"
```

**关键注意点：**
- 分区表完全复用官方的，确保 GRUB 引导兼容
- btrfs 子卷 @ 与挂载选项 subvol=@ 必须严格对应
- GRUB 配置中的 UUID 必须更新（因为重新 mkfs 会生成新 UUID）
- rootfstype 也要从 ext4 改为 btrfs

### 5.5 阶段 4: finalize.sh

**职责：** 格式转换、自检、生成校验和

**关键操作：**

```bash
ALPINE_VERSION=$(grep ALPINE_VERSION config/source.env | cut -d'"' -f2)
INPUT="build/output-${BOOT_TYPE}.img"
OUTPUT="output/slim-alpine-${ALPINE_VERSION}-${BOOT_TYPE}.qcow2"

mkdir -p output

# 1. 转换为 qcow2（v3 默认，不压缩，最大兼容性）
qemu-img convert -p -O qcow2 "$INPUT" "$OUTPUT"

# 2. 严格自检
echo "=== qemu-img info 自检 ==="
qemu-img info "$OUTPUT"

# 3. 检查格式合规性
INFO=$(qemu-img info --output=json "$OUTPUT")
echo "$INFO" | python3 -c '
import json, sys
info = json.load(sys.stdin)

errors = []
# 检查格式
if info.get("format") != "qcow2":
    errors.append(f"格式错误: {info.get(\"format\")}")

# 检查 compat
fmt = info.get("format-specific", {})
if fmt.get("type") == "qcow2":
    data = fmt.get("data", {})
    compat = data.get("compat")
    if compat not in ("1.1", "0.10"):
        errors.append(f"compat 值异常: {compat}")
    if data.get("encrypt"):
        errors.append("不应有加密")
    if data.get("compression-type"):
        errors.append(f"不应有 compression-type: {data[\"compression-type\"]}")
    if data.get("extended-l2"):
        errors.append("不应启用 extended-l2")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print("✅ 格式自检通过")
'

# 4. qemu-img check
qemu-img check "$OUTPUT"

# 5. 生成 SHA256
sha256sum "$OUTPUT" > "$OUTPUT.sha256"

# 6. 输出文件信息
echo "=== 最终产物 ==="
ls -lh "$OUTPUT" "$OUTPUT.sha256"
```

### 5.6 阶段 5: test-boot.sh

**职责：** 用 qemu 实际启动镜像验证

**关键操作：**

```bash
ALPINE_VERSION=$(grep ALPINE_VERSION config/source.env | cut -d'"' -f2)
IMG="output/slim-alpine-${ALPINE_VERSION}-${BOOT_TYPE}.qcow2"
TIMEOUT="${TIMEOUT:-120}"

# 准备临时副本（避免污染原镜像）
TEST_IMG=$(mktemp --suffix=.qcow2)
cp "$IMG" "$TEST_IMG"
trap "rm -f $TEST_IMG" EXIT

# 构建 qemu 命令
QEMU_ARGS=(
  -m 512
  -smp 2
  -drive "file=$TEST_IMG,format=qcow2,if=virtio"
  -nographic
  -serial mon:stdio
  -no-reboot
)

# UEFI 版本需要 OVMF 固件
if [ "$BOOT_TYPE" = "uefi" ]; then
  QEMU_ARGS+=(-bios /usr/share/ovmf/OVMF.fd)
fi

# 启动，等待 login 提示
expect <<EOF
set timeout $TIMEOUT
spawn qemu-system-x86_64 ${QEMU_ARGS[@]}
expect {
  "login:" {
    puts "\n✅ 启动成功"
    exit 0
  }
  "Kernel panic" {
    puts "\n❌ 内核 panic"
    exit 1
  }
  timeout {
    puts "\n❌ 超时未出现 login 提示"
    exit 2
  }
}
EOF
```

---

## 6. GitHub Actions Workflow

### 6.1 完整 workflow 文件

```yaml
# .github/workflows/build.yml

name: Build Slim Alpine Cloud Image

on:
  push:
    branches:
      - main
      - master
    paths:
      - 'scripts/**'
      - 'config/**'
      - '.github/workflows/build.yml'

  # 仍保留手动触发选项（便于重建）
  workflow_dispatch:
    inputs:
      release_tag:
        description: '可选：自定义 Release 标签'
        required: false

jobs:
  build:
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        boot_type: [uefi, bios]

    permissions:
      contents: write

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Install build dependencies
        run: |
          sudo bash scripts/00-prepare.sh \
            --boot ${{ matrix.boot_type }}

      - name: Extract official rootfs
        run: |
          sudo bash scripts/01-extract.sh \
            --boot ${{ matrix.boot_type }}

      - name: Customize (slim down)
        run: |
          sudo bash scripts/02-customize.sh \
            --boot ${{ matrix.boot_type }}

      - name: Build btrfs image
        run: |
          sudo bash scripts/03-build-image.sh \
            --boot ${{ matrix.boot_type }}

      - name: Finalize image
        run: |
          sudo bash scripts/04-finalize.sh \
            --boot ${{ matrix.boot_type }}

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: slim-alpine-${{ matrix.boot_type }}
          path: |
            output/slim-alpine-*.qcow2
            output/slim-alpine-*.sha256
          retention-days: 7

  test:
    needs: build
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        boot_type: [uefi, bios]
    steps:
      - uses: actions/checkout@v4

      - name: Install QEMU + OVMF
        run: |
          sudo apt-get update
          sudo apt-get install -y qemu-system-x86 ovmf expect

      - name: Download artifact
        uses: actions/download-artifact@v4
        with:
          name: slim-alpine-${{ matrix.boot_type }}
          path: output/

      - name: Boot test
        run: |
          sudo bash scripts/05-test-boot.sh \
            --boot ${{ matrix.boot_type }} \
            --timeout 120

  release:
    needs: test
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Download all artifacts
        uses: actions/download-artifact@v4
        with:
          path: output/
          merge-multiple: true

      - name: Generate combined SHA256SUMS
        run: |
          cd output
          sha256sum *.qcow2 > SHA256SUMS
          cat SHA256SUMS

      - name: Determine release tag
        id: tag
        run: |
          if [ -n "${{ inputs.release_tag }}" ]; then
            TAG="${{ inputs.release_tag }}"
          else
            ALPINE_VER=$(grep ALPINE_VERSION config/source.env | cut -d'"' -f2)
            TAG="v${ALPINE_VER}-slim-$(date +%Y%m%d-%H%M%S)"
          fi
          echo "tag=$TAG" >> $GITHUB_OUTPUT

      - name: Generate release notes
        run: |
          ALPINE_VER=$(grep ALPINE_VERSION config/source.env | cut -d'"' -f2)
          cat > release_notes.md <<EOF
          # Slim Alpine Cloud Image - ${{ steps.tag.outputs.tag }}

          基于 Alpine Linux ${ALPINE_VER} 官方 cloud 镜像精简构建，针对阿里云 ECS 优化。

          ## 产物
          - \`slim-alpine-${ALPINE_VER}-uefi.qcow2\` - UEFI 启动版本
          - \`slim-alpine-${ALPINE_VER}-bios.qcow2\` - BIOS 启动版本

          ## 默认凭据
          ⚠️ **首次登录后请立即修改密码！**
          - 用户名: \`root\`
          - 密码: \`slimalpine123\`

          ## 文件系统
          - 根分区: btrfs + zstd:9 透明压缩
          - 新写入文件自动压缩
          - 支持磁盘自动扩容（依赖 cloud-init）

          ## 内置工具
          ping, wget, curl, nano, chrony

          ## 校验
          请使用 \`SHA256SUMS\` 文件验证镜像完整性。
          EOF

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ steps.tag.outputs.tag }}
          name: ${{ steps.tag.outputs.tag }}
          body_path: release_notes.md
          files: |
            output/*.qcow2
            output/SHA256SUMS
```

### 6.2 关键设计点

**1. push 触发 + paths 过滤**
- 仅在 scripts/、config/、workflow 文件变更时触发
- 修改 README/docs 不会触发构建

**2. workflow_dispatch 保留**
- 便于手动重建（如官方发新版本后）

**3. matrix 并行**
- UEFI 和 BIOS 同时构建，缩短总时长

**4. 三阶段 job**
- build → test → release
- 任一阶段失败都阻止后续

**5. 自动 Release tag**
- 默认：`v{alpine版本}-slim-{时间戳}`
- 可手动覆盖（workflow_dispatch 时）

---

## 7. 测试与发布策略

### 7.1 多层测试

| 层级 | 测试内容 | 失败处理 |
|------|---------|---------|
| 构建期自检 | 文件存在性、SHA256、qemu-img info | 中断构建 |
| 格式合规性 | compat、encrypt、compression-type 等 | 中断构建 |
| qemu-img check | 镜像结构损坏检测 | 中断构建 |
| qemu 启动测试 | 实际启动到 login 提示符 | 中断流程，不发布 |

### 7.2 发布流程

```
push 触发
  → build (uefi + bios 并行)
  → test  (uefi + bios 并行启动测试)
  → release (合并产物 + 创建 Release)
```

### 7.3 用户使用流程（写入 docs/USAGE.md）

#### 步骤 1：选择对应镜像
- ECS 实例支持 UEFI（推荐，如 g7/c7/g8）→ 下载 uefi.qcow2
- ECS 实例仅支持 BIOS（如老的 g6/c6）→ 下载 bios.qcow2

#### 步骤 2：上传到阿里云 OSS
```bash
# 用 ossutil 分片上传，更稳定
ossutil cp -u slim-alpine-3.23.4-uefi.qcow2 \
  oss://<your-bucket>/slim-alpine-3.23.4-uefi.qcow2 \
  --part-size 104857600 --parallel 8
```

#### 步骤 3：在阿里云 ECS 控制台导入
1. 镜像服务 → 自定义镜像 → 从 OSS 导入
2. 镜像格式：`qcow2`
3. 操作系统：`Linux`
4. 系统版本：`Others Linux`
5. 系统盘大小：≥ 1GB（推荐 ≥ 20GB 利用 btrfs 自动扩容）
6. 架构：`x86_64`
7. 启动模式：与镜像匹配（UEFI / BIOS）

#### 步骤 4：创建 ECS 实例
- 选择刚导入的自定义镜像
- 首次启动 cloud-init 会自动扩容磁盘
- SSH 登录：root / slimalpine123
- **立即修改密码：`passwd`**

---

## 8. 风险与缓解措施

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| 默认密码泄露 | 安全风险 | README 与 Release notes 多处提醒立即修改 |
| 阿里云 qcow2 格式校验失败 | 镜像无法导入 | finalize.sh 严格自检；保守使用默认 qemu-img convert 参数 |
| GRUB UUID 替换错误 | 镜像无法启动 | test-boot.sh 自动启动测试拦截；UUID 通过 blkid 动态获取 |
| 内核模块误删导致启动失败 | 镜像无法启动 | 黑名单第一版保守；test-boot.sh 验证；保留 modprobe.d 黑名单作为软兜底 |
| btrfs 配置错误导致挂载失败 | 镜像无法启动 | 直接复用 longsays 已实战验证的参数；test-boot.sh 验证 |
| 阿里云元数据服务问题 | 自动扩容失败 | cloud-init 完整保留；用户可手动 `growpart + btrfs filesystem resize` |
| GitHub Actions 构建超时 | 镜像构建失败 | matrix 并行；单镜像构建预估 10-15min，远低于 6 小时上限 |
| Alpine 官方镜像 SHA256 变更 | 下载校验失败 | source.env 集中管理；版本升级时同步更新 |

---

## 9. 未来迭代计划

### v2 计划（基于第一版反馈）

- **进一步精简**：
  - 分析实际启动镜像后未加载的内核模块，扩大黑名单
  - 评估是否可卸载某些 cloud-init 模块（如非阿里云 datasource）
- **更激进的优化**：
  - 尝试 `cluster_size=512k`（参考 longsays 实测）
  - 尝试 qcow2 `-c` 压缩（如果实测阿里云接受）
- **多版本支持**：
  - 通过 matrix 同时构建多个 Alpine 版本
- **自动更新**：
  - 监听 Alpine 官方版本发布，自动触发构建

### v3 远期

- 支持 ARM64 架构
- 支持其他云平台（AWS、GCP、Azure）
- 提供 RAW、VHD 格式（如有需求）
- 集成自动上传 OSS + 导入阿里云镜像服务

---

## 10. 参考资料

- Alpine Linux Cloud Images: <https://alpinelinux.org/cloud/>
- longsays/debian-btrfs（btrfs 压缩参考实现）: <https://github.com/longsays/debian-btrfs>
- 阿里云导入自定义镜像: <https://help.aliyun.com/zh/ecs/user-guide/import-a-custom-image>
- 阿里云转换镜像格式: <https://help.aliyun.com/zh/ecs/user-guide/convert-the-format-of-an-image>
- QEMU qcow2 规范: <https://www.qemu.org/docs/master/interop/qcow2.html>
- cloud-init 模块文档: <https://cloudinit.readthedocs.io/en/latest/topics/modules.html>
- btrfs 挂载选项: <https://btrfs.readthedocs.io/en/latest/Administration.html>

---

## 附录 A：完整脚本调用示例（本地构建）

```bash
# 完整构建 UEFI 版本
sudo bash scripts/00-prepare.sh --boot uefi
sudo bash scripts/01-extract.sh --boot uefi
sudo bash scripts/02-customize.sh --boot uefi
sudo bash scripts/03-build-image.sh --boot uefi
sudo bash scripts/04-finalize.sh --boot uefi
sudo bash scripts/05-test-boot.sh --boot uefi --timeout 120

# 完整构建 BIOS 版本
sudo bash scripts/00-prepare.sh --boot bios
# ... 后续同上，--boot bios

# 产物在 output/ 目录
ls -lh output/
```

## 附录 B：调试技巧

如果某一阶段失败，可单独重跑：
- `01-extract.sh` 失败：检查官方镜像下载是否完整
- `02-customize.sh` 失败：进入 `build/rootfs-<boot>/` 手动 chroot 调试
- `03-build-image.sh` 失败：检查 losetup/kpartx 资源是否释放
- `04-finalize.sh` 失败：运行 `qemu-img info <file>` 查看具体格式问题
- `05-test-boot.sh` 失败：去掉 `-nographic`，加 `-display gtk` 本地启动查看错误
