# Slim Alpine Cloud Image

基于 Alpine Linux 官方 cloud 镜像构建的精简版云镜像，针对**阿里云 ECS** 优化。

- **基础系统**：Alpine Linux 3.23.4（可参数化）
- **文件系统**：btrfs + zstd:9 透明压缩
- **架构**：x86_64
- **格式**：qcow2（v3 默认，无压缩，最大兼容）
- **启动方式**：UEFI 与 BIOS 两个独立镜像
- **目标体积**：1GB 虚拟磁盘，qcow2 实际约 300-500MB
- **cloud-init**：完整保留，阿里云 datasource 优先

## 快速开始

### 下载预构建镜像

前往 [Releases](../../releases) 下载最新版本：

- `slim-alpine-<ver>-uefi.qcow2` — UEFI 启动（推荐，适合 g7/c7/g8 等新规格）
- `SHA256SUMS` — 校验和

> ⚠️ **BIOS 启动版本暂未支持**：Alpine 官方 BIOS cloud 镜像是裸 ext4（无分区表 + syslinux 引导），与 UEFI 路径完全不同，需额外适配。仅 UEFI 启动方式下载可用。

```bash
sha256sum -c SHA256SUMS
```

详细部署步骤见 [docs/USAGE.md](docs/USAGE.md)。

### 默认凭据

> ⚠️ **首次登录后请立即修改密码！**

| 项目 | 值 |
|------|----|
| 用户 | `root` |
| 密码 | `slimalpine123` |

修改密码：

```bash
passwd
```

## 本地构建

```bash
# UEFI 版本
sudo bash scripts/00-prepare.sh    --boot uefi
sudo bash scripts/01-extract.sh    --boot uefi
sudo bash scripts/02-customize.sh  --boot uefi
sudo bash scripts/03-build-image.sh --boot uefi
sudo bash scripts/04-finalize.sh   --boot uefi
sudo bash scripts/05-test-boot.sh  --boot uefi --timeout 180

# 产物
ls -lh output/
```

> BIOS 模式当前不可用，详见上方说明。

完整开发文档见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

## 仓库结构

```
.
├── .github/workflows/build.yml   # GitHub Actions 构建工作流
├── scripts/
│   ├── 00-prepare.sh             # 安装依赖、下载官方镜像
│   ├── 01-extract.sh             # 提取 rootfs
│   ├── 02-customize.sh           # chroot 精简（核心）
│   ├── 03-build-image.sh         # 创建 btrfs 镜像
│   ├── 04-finalize.sh            # 转 qcow2 + 严格自检
│   ├── 05-test-boot.sh           # qemu 启动测试
│   └── lib/                      # 公共函数库
├── config/                       # 集中管理的配置
│   ├── source.env                # 版本号、URL、btrfs 参数
│   ├── packages-install.list     # 要安装的工具
│   ├── packages-remove.list      # 要卸载的包
│   ├── kernel-modules-blacklist.conf
│   ├── kernel-modules-remove.list
│   └── cloud-init-aliyun.cfg
└── docs/
    ├── USAGE.md                  # 阿里云部署说明
    ├── DEVELOPMENT.md            # 本地构建/调试
    └── TROUBLESHOOTING.md        # 故障排查
```

## 主要设计决策

详细背景见 [`brainstorm/specs/2026-05-24-slim-alpine-cloud-image-design.md`](brainstorm/specs/2026-05-24-slim-alpine-cloud-image-design.md)。

- 复用 Alpine 官方 cloud 镜像的引导配置，避免手动安装 GRUB
- btrfs zstd:9 压缩，长期写入收益高
- qcow2 不加 `-c` 压缩，优先阿里云兼容性
- 第一版保守精简（黑名单模式），仅删明确不需要的硬件驱动
- 同时生成 UEFI 和 BIOS 两个独立镜像

## 许可

MIT，见 [LICENSE](LICENSE)。
