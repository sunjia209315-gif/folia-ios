#!/usr/bin/env bash
# ios.sh — 当前文件：Folia iOS 打包辅助脚本（同步 / 打开 / 运行 / 出包 / 环境自检）。
#
# 与 package.json 里的 ios:* npm script 等价，额外提供 macOS/Xcode 环境自检与 archive 出包。
# 这些步骤只能在 macOS 上执行：Electron 不支持 iOS，iOS 包用 Capacitor 把 dist/ 装进原生
# WKWebView 工程，Xcode 是必需工具链；在 Linux / Windows 上会直接报错退出。
#
# 用法:
#   ./ios.sh doctor    检查环境（macOS / Xcode / Node）
#   ./ios.sh sync      vite build 后 cap sync ios，把 dist/ 同步进原生工程
#   ./ios.sh open      用 Xcode 打开 ios/App/App.xcodeproj
#   ./ios.sh run       构建并部署到已连接的设备或模拟器
#   ./ios.sh archive   Release 配置 archive 出 App.xcarchive（需已配置签名）
#
# 常用环境变量:
#   VITE_FOLIA_API_BASE  打包时指向已部署的 Folia 后端（见 src/utils/webApiBase.ts）
#   IOS_SCHEME           archive 使用的 scheme，默认 App

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PROJECT="ios/App/App.xcodeproj"
SCHEME="${IOS_SCHEME:-App}"

die() { echo "✗ $*" >&2; exit 1; }
info() { echo "▶ $*"; }
ok() { echo "✓ $*"; }

# iOS 构建依赖 macOS 与 Xcode 命令行工具，非 macOS 环境直接拒绝执行。
require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "iOS 构建只能在 macOS 上进行（当前: $(uname -s)）。"
  command -v xcodebuild >/dev/null 2>&1 || die "未找到 xcodebuild，请先安装 Xcode 并运行 xcode-select --install。"
}

require_node() {
  command -v node >/dev/null 2>&1 || die "未找到 node，请先安装 Node.js（>= 24）。"
}

# 构建 Vite 产物并把 dist/ 同步进原生工程。
build_and_sync() {
  info "vite build"
  npx vite build
  info "cap sync ios"
  npx cap sync ios
  ok "已把 dist/ 同步进 $PROJECT"
}

cmd_doctor() {
  require_macos
  require_node
  echo "  macOS : $(sw_vers -productVersion)"
  echo "  Xcode : $(xcodebuild -version | head -1)"
  echo "  node  : $(node -v)"
  [[ -d "$PROJECT" ]] || die "缺少 $PROJECT，请先运行 npm run ios:add。"
  ok "环境就绪，可执行 ./ios.sh sync / open / run / archive"
}

cmd_sync() { require_macos; require_node; build_and_sync; }

cmd_open() { require_macos; npx cap open ios; }

cmd_run() { require_macos; require_node; build_and_sync; npx cap run ios; }

# Release archive。未配置签名团队时 xcodebuild 会失败，需先在 Xcode 里选好 Development Team。
cmd_archive() {
  require_macos
  require_node
  build_and_sync
  local out="$ROOT/build/ios"
  mkdir -p "$out"
  info "xcodebuild archive (-scheme $SCHEME)"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$out/App.xcarchive" \
    archive
  ok "产物: $out/App.xcarchive"
}

usage() {
  cat <<'EOF'
用法: ./ios.sh <command>

  doctor    检查 macOS / Xcode / Node 环境
  sync      vite build + cap sync ios
  open      用 Xcode 打开 iOS 工程
  run       构建并部署到设备或模拟器
  archive   Release 配置 archive 出 App.xcarchive

环境变量:
  VITE_FOLIA_API_BASE  打包时指向已部署的 Folia 后端
  IOS_SCHEME           archive 使用的 scheme，默认 App
EOF
}

case "${1:-}" in
  doctor) cmd_doctor ;;
  sync) cmd_sync ;;
  open) cmd_open ;;
  run) cmd_run ;;
  archive) cmd_archive ;;
  -h|--help|help|"") usage ;;
  *) die "未知命令: $1（运行 ./ios.sh --help 查看用法）" ;;
esac
