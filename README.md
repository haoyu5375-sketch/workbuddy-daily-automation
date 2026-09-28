# WorkBuddy 每日自动化：签到 + 派猫猫旅行

用 **GitHub Actions**（免费定时任务，云端 runner）每天自动完成：

1. **Buddy 加油站签到**（领每日积分）
2. **派猫猫旅行**：先领掉已经到家的旅行积分 → 再判断今天是否已派 → 没派过才派新的一趟

结果推送到 **企业微信**（签到 / 猫猫两段分开写清楚）。
凭证只来自仓库 Secrets，**不读本机登录态、不打印、不落盘**。

---

## 目录结构

```
workbuddy-daily-automation/
├── .github/workflows/daily.yml   # 定时任务（UTC 13:00 = 北京 21:00，每天一次）
├── scripts/run.sh                # 云端主脚本（签到 + 派猫猫旅行 + 企微推送）
├── scripts/refresh.sh            # 本机一次性：把登录态导出为 WB_AUTH secret
└── README.md
```

## 部署步骤

### 1. 建仓库
新建一个 GitHub 仓库（建议 **Private**），把这 4 个文件按目录结构提交。

### 2. 注入凭证 secret（本机执行一次）
在你**装了并登录过 WorkBuddy 桌面端**的电脑上：

```bash
bash scripts/refresh.sh owner/repo
```

- 若本机登录态是**明文**：脚本自动 `gh secret set WB_AUTH`。
- 若本机登录态已 **at-rest 加密**（`$wbEncrypted` 信封，2026-09 起部分桌面端启用，纯脚本解不出）：
  脚本会提示你改用「抓取明文 token 后手动 `gh secret set`」的方式（见下方「Token 来源」）。

> 云端 runner 没有本机登录态，因此走「refresh_token 自动续期」：
> `run.sh` 每次运行先用 `refresh_token` 调 `/v2/plugin/auth/token/refresh` 换出新 `access_token`，
> 只要有 refresh_token（约半年有效）就无需常开设备。

### 3. 在仓库 Settings → Secrets 添加

| Secret | 说明 |
|---|---|
| `WB_AUTH` | 由 refresh.sh 写入，JSON：`{"access_token","refresh_token","domain":"www.codebuddy.cn","uid"}` |
| `WB_WECOM_WEBHOOK` | 企微群机器人 Webhook 地址（**必填**，否则不推送） |
| `WB_CAT_STATUS_URL` | 派猫猫旅行「状态查询」接口（见下） |
| `WB_CAT_CLAIM_URL` | 派猫猫旅行「领取到家积分」接口 |
| `WB_CAT_DISPATCH_URL` | 派猫猫旅行「派出新程」接口 |
| `WB_CAT_TRAVEL_HOURS` | 出行时长（小时），默认 1 |

### 4. 抓取「派猫猫旅行」真实接口（关键）
本仓库**不臆测**猫猫接口名。请在你本机打开 WorkBuddy 桌面端 → 成长计划 → 派猫猫旅行，
用 **浏览器/系统代理的开发者工具（Network）** 抓取实际请求，把这三个 URL 填进对应 secret：

- 点「派去旅行」时发出的请求 → `WB_CAT_DISPATCH_URL`
- 「领取」回家积分时发出的请求 → `WB_CAT_CLAIM_URL`
- 进页面/刷新时拉取状态（含「是否到家」「今天是否已派」）的请求 → `WB_CAT_STATUS_URL`

接口鉴权与签到一致：`Authorization: Bearer <access_token>` + `X-Domain: www.codebuddy.cn`（必要时加 `X-User-Id`）。
字段名（如「今天是否已派」的布尔字段）以你抓到的实际响应为准，在 `run.sh` 的 `cat_maybe_dispatch()` 里按实际调整即可。

> 没填猫猫接口也没关系：脚本会跳过并提示，**不影响签到**。

### 5. 验收
在仓库 Actions 页面点 **Run workflow** 手动触发一次；或等每天北京 21:00 的定时。
企微会收到两段式消息，Actions 日志里也会打印脱敏后的原始返回（无 token）。

---

## 逻辑约束（已实现，请勿颠倒）

- 顺序固定：**先领已到家的积分 → 再判断派新程**；绝不「先派后领」。
- 领与派的判断写在两个独立函数 `cat_claim_arrived()` / `cat_maybe_dispatch()`。
- 猫猫部分整体容错：猫猫失败**不影响**签到结论；**签到成功即成功**（退出码 0）。
- 解释器（node / curl）全部用 `command -v` 动态获取，不写死版本号。
- token 仅随请求头发出，脚本任何位置不打印、不落盘。

## 注意事项

- GitHub 对 **60 天无活动**的仓库会**自动停用** scheduled workflows；长期不用时手动触发一次即可恢复。
- 定时触发时间以 UTC 计，受 GitHub 队列影响可能漂移，介意可把 `daily.yml` 的 cron 改成多个时间点。
- 若 `WB_AUTH` 里的 refresh_token 失效（约半年后或改密），重跑一次 `refresh.sh` 即可。
