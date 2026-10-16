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
#   ./ios.sh secrets   从 .p12 / .mobileprovision 自动写入 CI 签名 Secrets（详见 docs/technical.md）
#
# 常用环境变量:
#   VITE_FOLIA_API_BASE  打包时指向已部署的 Folia 后端（见 src/utils/webApiBase.ts）
#   IOS_SCHEME           archive 使用的 scheme，默认 App
#   IOS_CERT_PASSWORD    secrets 用的 .p12 密码（也可用 --password 传入）
#   FOLIA_IOS_REPO       secrets 的目标仓库，默认从 git remote 推断

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

# secrets 只需要 macOS 自带的 security / PlistBuddy 来解描述文件，不依赖 Xcode 工具链。
require_darwin() {
  [[ "$(uname -s)" == "Darwin" ]] || die "读取 .mobileprovision 需要 macOS 的 security 工具（当前: $(uname -s)）。"
  command -v security >/dev/null 2>&1 || die "未找到 security 命令。"
  [[ -x /usr/libexec/PlistBuddy ]] || die "未找到 /usr/libexec/PlistBuddy。"
}

require_gh() {
  command -v gh >/dev/null 2>&1 || die "未找到 gh（GitHub CLI），请先安装：brew install gh"
  gh auth status >/dev/null 2>&1 || die "gh 未登录，请先运行 gh auth login。"
}

# 从 git remote 推断 owner/repo；取不到时回落到环境变量或默认仓库。
default_repo() {
  local url
  url="$(git remote get-url folia-ios 2>/dev/null || git remote get-url origin 2>/dev/null || true)"
  url="$(printf '%s' "$url" | sed -E 's#^(git@|ssh://git@|https://|http://)github\.com[:/]##; s#\.git$##')"
  if [[ "$url" == */* ]]; then printf '%s' "$url"; else printf '%s' "${FOLIA_IOS_REPO:-sunjia209315-gif/folia-ios}"; fi
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

# 把 .p12 与 .mobileprovision 落成 CI 用的签名 Secrets：自动从描述文件读出
# Team ID 与名称，避免手工复制粘贴出错。只做「上传」，证书本身仍需从 Apple 开发者
# 后台申请，这部分无法自动化。
cmd_secrets() {
  local cert="" profile="" password="${IOS_CERT_PASSWORD:-}" method="" repo="" run_after=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cert)     cert="${2:-}";     shift 2 ;;
      --profile)  profile="${2:-}";  shift 2 ;;
      --password) password="${2:-}"; shift 2 ;;
      --method)   method="${2:-}";   shift 2 ;;
      --repo)     repo="${2:-}";     shift 2 ;;
      --run)      run_after=1;       shift ;;
      -h|--help)  usage; return 0 ;;
      *) die "secrets 未知参数: $1（运行 ./ios.sh --help 查看用法）" ;;
    esac
  done

  [[ -n "$cert" ]]    || die "缺少 --cert（导出的 .p12 路径）"
  [[ -f "$cert" ]]    || die "找不到证书文件: $cert"
  [[ -n "$profile" ]] || die "缺少 --profile（.mobileprovision 路径）"
  [[ -f "$profile" ]] || die "找不到描述文件: $profile"
  [[ -n "$password" ]] || die "缺少 .p12 密码：用 --password 传入，或设 IOS_CERT_PASSWORD 环境变量"
  if [[ -n "$method" ]]; then
    case "$method" in
      debugging|release-testing|app-store-connect) ;;
      *) die "--method 只能是 debugging / release-testing / app-store-connect" ;;
    esac
  fi

  require_darwin
  require_gh
  [[ -n "$repo" ]] || repo="$(default_repo)"

  local tmp team profile_name
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  # .mobileprovision 是 CMS 签名包，先解出内嵌 plist 才能读到 TeamIdentifier 与 Name。
  security cms -D -i "$profile" > "$tmp/profile.plist" 2>/dev/null \
    || die "无法解析描述文件，请确认它是 .mobileprovision（不是 .p12 或 .cer）"
  team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$tmp/profile.plist" 2>/dev/null)" \
    || die "描述文件里读不到 TeamIdentifier"
  profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$tmp/profile.plist" 2>/dev/null)" \
    || die "描述文件里读不到 Name"

  info "目标仓库     : $repo"
  info "Team ID      : $team"
  info "Profile 名称 : $profile_name"
  [[ -z "$method" ]] || info "导出方式     : $method"

  base64 -i "$cert"    > "$tmp/cert.b64"
  base64 -i "$profile" > "$tmp/profile.b64"

  gh secret set IOS_CERT_P12             --repo "$repo" < "$tmp/cert.b64"
  gh secret set IOS_PROVISIONING_PROFILE --repo "$repo" < "$tmp/profile.b64"
  gh secret set IOS_TEAM_ID              --repo "$repo" -b "$team"
  gh secret set IOS_PROFILE_SPECIFIER    --repo "$repo" -b "$profile_name"
  # 密码走 stdin，避免出现在进程参数里。
  printf '%s' "$password" | gh secret set IOS_CERT_PASSWORD --repo "$repo"
  [[ -z "$method" ]] || gh variable set IOS_EXPORT_METHOD --repo "$repo" -b "$method"

  ok "Secrets 已写入 $repo"
  gh secret list --repo "$repo"

  if (( run_after )); then
    info "触发 ios-build workflow"
    gh workflow run ios-build.yml --repo "$repo"
    sleep 8
    local run_id
    run_id="$(gh run list --repo "$repo" --workflow=ios-build.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
    [[ -n "$run_id" ]] || die "未能取到 run id，请到 Actions 页面手动查看"
    info "跟踪 run $run_id"
    gh run watch "$run_id" --repo "$repo" --exit-status
  fi

  ok "完成。若未跑 workflow，可执行：gh workflow run ios-build.yml --repo $repo"
}

usage() {
  cat <<'EOF'
用法: ./ios.sh <command>

  doctor    检查 macOS / Xcode / Node 环境
  sync      vite build + cap sync ios
  open      用 Xcode 打开 iOS 工程
  run       构建并部署到设备或模拟器
  archive   Release 配置 archive 出 App.xcarchive
  secrets   从 .p12 / .mobileprovision 自动写入 CI 签名 Secrets

secrets 用法:
  ./ios.sh secrets --cert cert.p12 --profile folia.mobileprovision [选项]

    --cert <路径>       导出的 .p12 证书（必须含私钥）
    --profile <路径>    .mobileprovision 描述文件
    --password <密码>   .p12 密码；省略时读环境变量 IOS_CERT_PASSWORD
    --method <方式>     debugging | release-testing | app-store-connect
                        省略则不设，沿用 workflow 默认的 debugging
    --repo <owner/repo> 目标仓库；省略时从 git remote 推断
    --run               写完后立即触发并跟踪一次 workflow 运行

环境变量:
  VITE_FOLIA_API_BASE  打包时指向已部署的 Folia 后端
  IOS_SCHEME           archive 使用的 scheme，默认 App
  IOS_CERT_PASSWORD    .p12 密码（避免明文出现在命令历史里）
  FOLIA_IOS_REPO       secrets 的目标仓库
EOF
}

case "${1:-}" in
  doctor) cmd_doctor ;;
  sync) cmd_sync ;;
  open) cmd_open ;;
  run) cmd_run ;;
  archive) cmd_archive ;;
  secrets) shift; cmd_secrets "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "未知命令: $1（运行 ./ios.sh --help 查看用法）" ;;
esac
