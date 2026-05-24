#!/usr/bin/env bash
# scripts/lib/common.sh
# 公共函数：日志、参数解析、错误处理、清理。
# 由所有阶段脚本通过 `source` 引入。

set -Eeuo pipefail

# ---------- 颜色与日志 ----------

if [ -t 1 ]; then
  _CLR_RESET="\033[0m"
  _CLR_BLUE="\033[1;34m"
  _CLR_GREEN="\033[1;32m"
  _CLR_YELLOW="\033[1;33m"
  _CLR_RED="\033[1;31m"
else
  _CLR_RESET=""; _CLR_BLUE=""; _CLR_GREEN=""; _CLR_YELLOW=""; _CLR_RED=""
fi

log_info()  { printf "%b[INFO]%b  %s\n" "$_CLR_BLUE"   "$_CLR_RESET" "$*"; }
log_ok()    { printf "%b[OK]%b    %s\n" "$_CLR_GREEN"  "$_CLR_RESET" "$*"; }
log_warn()  { printf "%b[WARN]%b  %s\n" "$_CLR_YELLOW" "$_CLR_RESET" "$*" >&2; }
log_error() { printf "%b[ERROR]%b %s\n" "$_CLR_RED"    "$_CLR_RESET" "$*" >&2; }

die() { log_error "$*"; exit 1; }

# ---------- 参数解析 ----------
# 用法：parse_args "$@"
# 解析 --boot uefi|bios，导出 BOOT_TYPE 变量。
parse_args() {
  BOOT_TYPE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --boot)
        [ $# -ge 2 ] || die "--boot 需要参数"
        BOOT_TYPE="$2"
        shift 2
        ;;
      --boot=*)
        BOOT_TYPE="${1#--boot=}"
        shift
        ;;
      -h|--help)
        printf "用法: %s --boot uefi|bios\n" "${0##*/}"
        exit 0
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
  done

  case "$BOOT_TYPE" in
    uefi|bios) ;;
    "")        die "缺少 --boot 参数（uefi 或 bios）" ;;
    *)         die "--boot 必须为 uefi 或 bios，收到: $BOOT_TYPE" ;;
  esac

  export BOOT_TYPE
}

# ---------- 路径解析 ----------

# 项目根目录：从 lib/ 上溯两层
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PROJECT_ROOT

# 标准目录
export BUILD_DIR="$PROJECT_ROOT/build"
export OUTPUT_DIR="$PROJECT_ROOT/output"
export CONFIG_DIR="$PROJECT_ROOT/config"

# 加载 source.env（提供 ALPINE_VERSION 等变量）
load_source_env() {
  # shellcheck source=/dev/null
  source "$CONFIG_DIR/source.env"
}

# ---------- 清理钩子 ----------
# 子脚本可调用 register_cleanup <cmd> 注册清理动作。
# 退出（无论正常或失败）时按 LIFO 执行。

_CLEANUP_CMDS=()

register_cleanup() {
  _CLEANUP_CMDS+=("$*")
}

_run_cleanup() {
  local i
  for ((i=${#_CLEANUP_CMDS[@]}-1; i>=0; i--)); do
    # shellcheck disable=SC2086
    eval "${_CLEANUP_CMDS[$i]}" || true
  done
}

trap _run_cleanup EXIT

# ---------- 错误兜底 ----------

_on_err() {
  local exit_code=$?
  log_error "脚本在 ${BASH_SOURCE[1]:-?}:${BASH_LINENO[0]:-?} 失败（exit=$exit_code）"
  exit $exit_code
}
trap _on_err ERR

# ---------- 通用工具 ----------

require_root() {
  [ "$(id -u)" -eq 0 ] || die "本脚本必须以 root 运行（用 sudo）"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
  done
}

ensure_dir() {
  local d
  for d in "$@"; do
    mkdir -p "$d"
  done
}
