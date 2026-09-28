#!/usr/bin/env bash
# =============================================================================
# WorkBuddy 每日任务：Buddy 加油站签到 + 派猫猫旅行
# 部署目标：GitHub Actions（云端 ubuntu runner，无本机登录态）
#
# 设计要点（对应需求）：
#   1) 每天跑一次，一次把「签到」和「派猫」都做掉。
#   2) 顺序固定：先领掉已经到家的旅行积分，再判断能不能派新的一趟；
#      今天已经派过就别派。领和派的判断写成两个独立函数，绝不颠倒。
#   3) 结果推送到企业微信，签到 / 猫猫两段分开写清楚。
#   4) 猫猫部分整体容错：猫猫失败不影响签到结论，签到成功即成功。
#
# 凭证：仅来自仓库 secret（WB_AUTH），不读本机登录态、不打印、不落盘。
# 解释器：全部用 command -v 动态获取，不写死版本号。
# =============================================================================
set -uo pipefail

# ------------------------------------------------------------------ 解释器动态获取
NODE_BIN="$(command -v node || true)"
CURL_BIN="$(command -v curl || command -v curl.exe || true)"
if [ -z "$NODE_BIN" ] || [ -z "$CURL_BIN" ]; then
  echo "❌ 缺少必要解释器：node=$([ -n "$NODE_BIN" ] && echo ok || echo MISSING) curl=$([ -n "$CURL_BIN" ] && echo ok || echo MISSING)"
  exit 2
fi

# ------------------------------------------------------------------ 接口（以实际请求为准）
BASE="https://copilot.tencent.com"
REFRESH_URL="$BASE/v2/plugin/auth/token/refresh"
CHECKIN_STATUS_URL="$BASE/v2/billing/meter/checkin-status"
CHECKIN_URL="$BASE/v2/billing/meter/daily-checkin"

# 猫猫接口：本机无法从源码取得真实路径，统一走 secret 配置（见 README 如何抓取）。
# 留空 = 该步骤跳过并提示，不影响签到。
CAT_STATUS_URL="${WB_CAT_STATUS_URL:-}"      # 查询旅行状态（是否到家 / 今天是否已派）
CAT_CLAIM_URL="${WB_CAT_CLAIM_URL:-}"        # 领取已到家旅行的积分
CAT_DISPATCH_URL="${WB_CAT_DISPATCH_URL:-}"   # 派出新一趟旅行
CAT_HOURS="${WB_CAT_TRAVEL_HOURS:-1}"         # 出行时长（小时），默认 1

WEBHOOK="${WB_WECOM_WEBHOOK:-}"

DRY_RUN="${WB_DRY_RUN:-0}"
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# ------------------------------------------------------------------ JSON 取值（用 node，免依赖 jq）
node_path() {
  local p="$1"
  "$NODE_BIN" -e 'const fs=require("fs");let raw="";try{raw=fs.readFileSync(0,"utf8");}catch(e){raw="";}let v;try{const j=JSON.parse(raw);const ks=process.argv[1].split(".");v=j;for(const k of ks){if(v==null){v=undefined;break;}v=v[k];}}catch(e){v=undefined;}console.log(v==null?"":(typeof v==="object"?JSON.stringify(v):String(v)));' "$p"
}

# ------------------------------------------------------------------ HTTP POST
# token 只在 Authorization 头里随请求发出，脚本任何位置都不回显、不落盘。
api_call() {
  local kind="$1"; local url="$2"; local body="$3"
  if [ "$DRY_RUN" = "1" ]; then
    dry_response "$kind"
    return
  fi
  "$CURL_BIN" -s -m 20 -X POST "$url" \
    -H "Authorization: Bearer $AT" \
    -H "X-User-Id: $UIDV" \
    -H "X-Domain: $DOMAIN" \
    -H "Content-Type: application/json" \
    -d "$body"
}

# 仅用于 --dry-run 的本地逻辑验证（非真实网络，非真实返回）
dry_response() {
  case "$1" in
    refresh)        echo '{"code":0,"msg":"OK","data":{"accessToken":"dry_AT_xxxx"}}' ;;
    checkin_status) echo '{"code":0,"data":{"today_checked_in":false,"continuousDays":6}}' ;;
    checkin)        echo '{"code":0,"msg":"success","data":{"points":100,"continuousDays":7,"today_checked_in":true}}' ;;
    cat_status)     if [ "${WB_DRY_CAT_DISPATCHED:-0}" = "1" ]; then
                      echo '{"code":0,"data":{"arrived":[{"id":"t1","points":8}],"dispatchedToday":true}}'
                    else
                      echo '{"code":0,"data":{"arrived":[{"id":"t1","points":8}],"dispatchedToday":false}}'
                    fi ;;
    cat_claim)      echo '{"code":0,"data":{"points":8}}' ;;
    cat_dispatch)   echo '{"code":0,"data":{"tripId":"T20260928","hours":'"$CAT_HOURS"'}}' ;;
    *)              echo '{"code":0}' ;;
  esac
}

# ------------------------------------------------------------------ 读取凭证（仅来自 secret）
RAW_AUTH="${WB_AUTH:-}"
if [ -z "$RAW_AUTH" ] && [ "$DRY_RUN" != "1" ]; then
  echo "❌ 未找到 WB_AUTH secret。请先在仓库 Secrets 配置（明文仅经 gh secret set 入库，见 README）。"
  exit 2
fi
[ -z "$RAW_AUTH" ] && RAW_AUTH='{"access_token":"dry","refresh_token":"dry","domain":"www.codebuddy.cn","uid":"dry"}'
AT="$(printf '%s' "$RAW_AUTH" | node_path access_token)"
REFRESH_TOKEN="$(printf '%s' "$RAW_AUTH" | node_path refresh_token)"
DOMAIN="$(printf '%s' "$RAW_AUTH" | node_path domain)"; [ -z "$DOMAIN" ] && DOMAIN="www.codebuddy.cn"
UIDV="$(printf '%s' "$RAW_AUTH" | node_path uid)"
[ "$DRY_RUN" = "1" ] && { AT="dry_AT_xxxx"; REFRESH_TOKEN="dry_RT_xxxx"; }

# ------------------------------------------------------------------ 云端用 refresh_token 续期 access_token
# 这样无需常开设备：只要 refresh_token 有效（约半年），每次运行先换出新 access_token。
if [ -n "$REFRESH_TOKEN" ] && [ "$DRY_RUN" != "1" ]; then
  RREF="$(api_call refresh "$REFRESH_URL" '{}')"
  NAT="$(printf '%s' "$RREF" | node_path data.accessToken)"
  if [ -n "$NAT" ]; then AT="$NAT"; fi
fi

# ================================================================== 一、签到
CHECKIN_OK=0; CHECKIN_MSG=""; CHECKIN_RAW=""
do_checkin() {
  SSTAT="$(api_call checkin_status "$CHECKIN_STATUS_URL" '{}')"   # 仅取信息，不强制
  SRESP="$(api_call checkin "$CHECKIN_URL" '{}')"
  CHECKIN_RAW="$SRESP"
  local code="$(printf '%s' "$SRESP" | node_path code)"
  if [ "$code" = "0" ] || [ "$code" = "10001" ]; then
    CHECKIN_OK=1
    local pts="$(printf '%s' "$SRESP" | node_path data.points)"
    local days="$(printf '%s' "$SRESP" | node_path data.continuousDays)"
    if [ "$code" = "10001" ]; then CHECKIN_MSG="今日已签到（接口返回 10001）"
    else CHECKIN_MSG="签到成功"; fi
    [ -n "$pts" ]  && CHECKIN_MSG="$CHECKIN_MSG，本次积分 $pts"
    [ -n "$days" ] && CHECKIN_MSG="$CHECKIN_MSG，连续 $days 天"
  else
    CHECKIN_OK=0
    CHECKIN_MSG="签到失败（code=$code，见原始返回）"
  fi
}

# ================================================================== 二、派猫猫旅行
# 两个判断完全分离；顺序固定为「先领后派」，严禁颠倒（需求硬约束）。
CAT_CLAIM_MSG=""; CAT_DISPATCH_MSG=""; CAT_FAILED=0
CAT_CLAIM_RAW=""; CAT_STATUS_RAW=""; CAT_DISPATCH_RAW=""

# --- 函数一：领取已到家的旅行积分（与“派新程”判断分离）---
cat_claim_arrived() {
  if [ -z "$CAT_CLAIM_URL" ]; then CAT_CLAIM_MSG="领积分：接口未配置，跳过（请在 Secrets 填 WB_CAT_CLAIM_URL）"; return; fi
  local r="$(api_call cat_claim "$CAT_CLAIM_URL" '{}')"
  CAT_CLAIM_RAW="$r"
  local code="$(printf '%s' "$r" | node_path code)"
  local got="$(printf '%s' "$r" | node_path data.points)"
  if [ "$code" = "0" ]; then
    CAT_CLAIM_MSG="领积分：已领取${got:+ $got 分}（到家的旅行）"
  else
    CAT_CLAIM_MSG="领积分：接口返回异常 code=$code"
  fi
}

# --- 函数二：判断今天是否已派；没派过才派新的一趟（绝不先于“领”执行）---
cat_maybe_dispatch() {
  local dispatched_today=0
  if [ -n "$CAT_STATUS_URL" ]; then
    local s="$(api_call cat_status "$CAT_STATUS_URL" '{}')"
    CAT_STATUS_RAW="$s"
    # “今天已派过”的判定字段以实际接口为准，这里取常见字段
    local dt="$(printf '%s' "$s" | node_path data.dispatchedToday)"
    [ "$dt" = "true" ] && dispatched_today=1
  fi
  if [ "$dispatched_today" = "1" ]; then
    CAT_DISPATCH_MSG="派新程：今天已派过，跳过"
    return
  fi
  if [ -z "$CAT_DISPATCH_URL" ]; then
    CAT_DISPATCH_MSG="派新程：接口未配置，跳过（请在 Secrets 填 WB_CAT_DISPATCH_URL）"
    return
  fi
  local body="$(printf '{"hours":%s}' "${CAT_HOURS}")"
  local d="$(api_call cat_dispatch "$CAT_DISPATCH_URL" "$body")"
  CAT_DISPATCH_RAW="$d"
  local code="$(printf '%s' "$d" | node_path code)"
  if [ "$code" = "0" ]; then
    CAT_DISPATCH_MSG="派新程：已派出（${CAT_HOURS} 小时）"
  else
    CAT_DISPATCH_MSG="派新程：接口返回异常 code=$code"
  fi
}

# ================================================================== 编排执行
do_checkin

# 猫猫部分：整体容错；即便报错也不影响上面的签到结论。
if [ "$DRY_RUN" = "1" ]; then
  cat_claim_arrived          # ① 先领已到家的积分
  cat_maybe_dispatch         # ② 再判今天是否派过、没派过才派
else
  {
    cat_claim_arrived        # ① 先领已到家的积分
    cat_maybe_dispatch       # ② 再判今天是否派过、没派过才派
  } || CAT_FAILED=1
fi

# ================================================================== 三、组装企微消息（两段分离）
build_message() {
  local md=""
  md+="## WorkBuddy 每日任务"$'\n'
  md+="> 执行时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"$'\n\n'
  md+="### 一、Buddy 加油站 · 签到"$'\n'
  md+="- 结论：$([ "$CHECKIN_OK" = "1" ] && echo '✅ 成功' || echo '❌ 失败')"$'\n'
  md+="- 详情：$CHECKIN_MSG"$'\n\n'
  md+="### 二、派猫猫旅行"$'\n'
  md+="- $CAT_CLAIM_MSG"$'\n'
  md+="- $CAT_DISPATCH_MSG"$'\n'
  if [ "$CAT_FAILED" = "1" ]; then
    md+="- 备注：猫猫部分执行异常，但**不影响签到结论**"$'\n'
  fi
  printf '%s' "$md"
}

MD="$(build_message)"
if [ -n "$WEBHOOK" ]; then
  PAYLOAD="$("$NODE_BIN" -e 'const c=process.argv[1];console.log(JSON.stringify({msgtype:"markdown",markdown:{content:c}}));' "$MD")"
  if [ "$DRY_RUN" != "1" ]; then
    "$CURL_BIN" -s -m 20 -X POST "$WEBHOOK" -H "Content-Type: application/json" -d "$PAYLOAD" >/dev/null 2>&1
  fi
fi

# ================================================================== 四、日志摘要（绝不出现 token）
echo "==================== 执行摘要（不含任何 token）===================="
echo "签到      ：$CHECKIN_MSG"
echo "猫猫-领   ：$CAT_CLAIM_MSG"
echo "猫猫-派   ：$CAT_DISPATCH_MSG"
echo "原始返回（脱敏，不含 token）："
echo "  checkin       : $CHECKIN_RAW"
[ -n "$CAT_CLAIM_RAW" ]    && echo "  cat_claim     : $CAT_CLAIM_RAW"
[ -n "$CAT_STATUS_RAW" ]   && echo "  cat_status    : $CAT_STATUS_RAW"
[ -n "$CAT_DISPATCH_RAW" ] && echo "  cat_dispatch  : $CAT_DISPATCH_RAW"
echo "=================================================================="

# 结论：签到成功即成功（猫猫失败不影响）
if [ "$CHECKIN_OK" = "1" ]; then exit 0; else exit 1; fi
