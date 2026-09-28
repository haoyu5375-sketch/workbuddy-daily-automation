#!/usr/bin/env bash
# =============================================================================
# 本地一次性：把 WorkBuddy 登录态导出为仓库 secret（WB_AUTH）。
# 只在你自己的本机（装了并登录过 WorkBuddy 桌面端）运行。
#
# 凭证只经 `gh secret set` 写入 GitHub 加密 secret，不打印、不落盘、不回显。
# 解释器（node / gh）均用 command -v 动态获取，不写死版本号。
#
# 用法：
#   bash scripts/refresh.sh owner/repo
#   （或 export WB_REPO=owner/repo 后直接 bash scripts/refresh.sh）
# =============================================================================
set -uo pipefail

NODE_BIN="$(command -v node || true)"
GH_BIN="$(command -v gh || true)"
if [ -z "$GH_BIN" ]; then
  echo "❌ 需要 gh CLI 且已登录：https://cli.github.com"
  exit 2
fi
if [ -z "$NODE_BIN" ]; then
  echo "❌ 需要 Node.js（用于解析登录态 JSON）"
  exit 2
fi

REPO="${1:-${WB_REPO:-}}"
if [ -z "$REPO" ]; then
  echo "用法: bash scripts/refresh.sh owner/repo"
  exit 2
fi

# 定位登录态文件（macOS / Windows / Linux 常见路径）
CANDIDATES=(
  "$HOME/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"
  "$LOCALAPPDATA/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"
  "$APPDATA/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"
  "$HOME/.config/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"
)
INFO=""
for f in "${CANDIDATES[@]}"; do
  if [ -f "$f" ]; then INFO="$f"; break; fi
done
if [ -z "$INFO" ]; then
  echo "❌ 未找到 workbuddy-desktop.info，请确认 WorkBuddy 桌面端已登录并打开过。"
  exit 2
fi
echo "✓ 找到登录态文件：$INFO"

# 解析：明文则直接导出；at-rest 加密信封则给出手动引导
OUT="$("$NODE_BIN" -e '
const fs=require("fs");
const p=process.argv[1];
const j=JSON.parse(fs.readFileSync(p,"utf8"));
const auth=j.auth||{};
const at=auth.accessToken, rt=auth.refreshToken;
const isStr=v=>v&&typeof v==="string";
const domain=auth.domain||"www.codebuddy.cn";
const uid=(j.account&&j.account.uid)||"";
if(isStr(at)&&isStr(rt)){
  console.log("OK\t"+JSON.stringify({access_token:at,refresh_token:rt,domain:domain,uid:uid}));
}else{
  console.log("ENCRYPTED");
}
' "$INFO")"

if [ "${OUT:0:2}" = "OK" ]; then
  PAYLOAD="${OUT#OK$'\t'}"
  # 仅经 gh 写入加密 secret，命令行参数不回显明文到终端日志之外
  printf '%s' "$PAYLOAD" | "$GH_BIN" secret set WB_AUTH -R "$REPO" >/dev/null
  echo "✅ 已将 WB_AUTH 写入仓库 $REPO 的 Secrets（GitHub 加密，日志不显示明文）。"
  echo "⚠️ 还需在仓库 Secrets 手动添加："
  echo "   - WB_WECOM_WEBHOOK ：企微群机器人 Webhook 地址"
  echo "   - WB_CAT_STATUS_URL / WB_CAT_CLAIM_URL / WB_CAT_DISPATCH_URL ：派猫猫旅行接口（从桌面端网络请求抓取，见 README）"
  echo "   - WB_CAT_TRAVEL_HOURS （可选，默认 1）"
else
  echo "⚠️ 本机登录态已启用 at-rest 加密（accessToken 为加密信封 \$wbEncrypted），纯脚本无法解密。"
  echo "请改用以下任一方式获取明文凭证后手动写入 secret："
  echo "  1) 在仍为明文版本的 WorkBuddy 上运行本脚本；或"
  echo "  2) 打开已登录的 WorkBuddy 桌面端，用代理 / 浏览器开发者工具抓取请求里的"
  echo "       Authorization: Bearer <access_token>  与  X-Refresh-Token: <refresh_token>，"
  echo "     连同 X-Domain(www.codebuddy.cn) 与 account.uid，执行："
  echo "     gh secret set WB_AUTH -R $REPO -b '{\"access_token\":\"<AT>\",\"refresh_token\":\"<RT>\",\"domain\":\"www.codebuddy.cn\",\"uid\":\"<UID>\"}'"
  exit 3
fi
