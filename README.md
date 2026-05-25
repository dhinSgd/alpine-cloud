# Slim Alpine Cloud Image

基于 Alpine Linux 官方 cloud 镜像构建的精简版云镜像，针对**阿里云 ECS** 优化。

- **基础系统**：Alpine Linux 3.23.4（可参数化）
- **文件系统**：btrfs + zstd:9 透明压缩
- **架构**：x86_64
- **格式**：qcow2（v3 默认，无压缩，最大兼容）
- **启动方式**：UEFI（qcow2 格式）
- **目标体积**：1GB 虚拟磁盘，qcow2 实际约 300-500MB
- **cloud-init**：完整保留，阿里云 datasource 优先

## 快速开始

### 下载预构建镜像

前往 [Releases](../../releases) 下载最新版本：

- `slim-alpine-<ver>-uefi.qcow2` — UEFI 启动（qcow2 格式）
- `SHA256SUMS` — 校验和

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

## SSH 密钥登录

镜像支持两种 SSH 公钥注入方式，互补不冲突：

### 方式一：阿里云控制台绑定密钥对（推荐）

创建 ECS 实例时勾选「密钥对」即可。开机后 cloud-init 会从阿里云元数据服务
（`http://100.100.100.200/latest/meta-data/public-keys/...`）拉取公钥并写入
`/root/.ssh/authorized_keys`，无需任何额外操作。

```bash
# 用对应私钥登录
ssh -i ~/.ssh/your_key root@<ecs_public_ip>
```

### 方式二：构建期预置（本地构建/CI 自动化场景）

构建前导出 `SSH_AUTHORIZED_KEYS` 环境变量，`02-customize.sh` 会将其写入镜像内的
`/root/.ssh/authorized_keys`（mode 600，owner root）。

```bash
# 单公钥
export SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)"

# 多公钥（每行一个）
export SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/key1.pub)
$(cat ~/.ssh/key2.pub)"

sudo -E bash scripts/02-customize.sh
# ... 其余阶段照常
```

构建日志只打印每个公钥的指纹（SHA256），不打印完整公钥。

### GitHub Actions 自动注入（无需配置）

CI 工作流会自动读取仓库内的固定测试公钥 [`config/test-ssh-public-key.pub`](config/test-ssh-public-key.pub)
并透传给 `02-customize.sh` 和 `05-test-boot.sh`。启动测试阶段会断言
`/root/.ssh/authorized_keys` 落盘正确并打印内容/指纹。

> 该公钥的私钥已在生成时销毁，**不存在持有者**、**无法用于真实登录**，仅用于验证注入流程。
> 如需轮换，重新生成 ed25519 密钥对、覆盖该文件、丢弃私钥即可。无需配置任何 GitHub secret。

### 密码登录与密钥登录共存

构建期注入公钥后**仍可用密码登录**（兜底 VNC 救援等场景）。若要强制只允许密钥登录，
登录后手动修改：

```bash
sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
rc-service sshd restart
```

## 本地构建

```bash
# 构建 UEFI 镜像
sudo bash scripts/00-prepare.sh
sudo bash scripts/01-extract.sh
sudo bash scripts/02-customize.sh
sudo bash scripts/03-build-image.sh
sudo bash scripts/04-finalize.sh
sudo bash scripts/05-test-boot.sh --timeout 180

# 产物
ls -lh output/
```

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
- 仅支持 UEFI 启动（qcow2 格式）

## 许可

MIT，见 [LICENSE](LICENSE)。
