# 微信扫码支付（WeChat Pay NATIVE）— 接入说明

> 适用：把 BNet 的投币口换成“顾客自己扫码付款、自己上机”。
> 顾客在投币机页点「微信扫码支付」→ 选金额 → 扫码付款 → 对应电脑自动解锁。
> 客户端（WinForms）不用改，解锁走的还是投币那条 WebSocket 消息。

## 改动清单

| 文件 | 改动 |
|---|---|
| `BNet.Cafe.Server/Services/WeChatPayHelper.cs` | 新增：微信支付 v2 签名（MD5）、XML 组装/解析、下单（unifiedorder）与查单（orderquery） |
| `BNet.Cafe.Server/Ashx/CreateWeChatPayOrderHandler.ashx(.cs)` | 新增：下单接口，返回 `codeUrl`（付款码内容）+ `outTradeNo` + 时长 |
| `BNet.Cafe.Server/Ashx/QueryWeChatPayOrderHandler.ashx(.cs)` | 新增：查单接口，返回 `paid` / `tradeState` |
| `BNet.Cafe.Server/Assets/Vendo/WeChatPay.js` | 新增：投币机页的付款流程（选金额 → 出付款码 → 轮询到账 → 建租用记录 → 发解锁指令） |
| `BNet.Cafe.Server/Web.config` | 新增 `WeChatPay_AppId / MchId / ApiKey / NotifyUrl` 四个配置项（空值，各店自己填） |

## 每家店要填的配置（Web.config → appSettings）

```xml
<add key="WeChatPay_AppId" value="wx…" />
<add key="WeChatPay_MchId" value="15…" />
<add key="WeChatPay_ApiKey" value="32 位 v2 API 密钥" />
<add key="WeChatPay_NotifyUrl" value="" />
```

- `AppId`：微信商户号绑定的公众号/开放平台 AppID。
- `MchId`：微信支付商户号。
- `ApiKey`：商户平台 → 账户设置 → API 安全 → 设置的 v2 API 密钥（32 位）。
- `NotifyUrl`：微信下单接口的必填字段，但**实际不会被调用**——网吧服务器在局域网，
  微信的回调推不进来，所以服务端改成主动轮询查单。留空会默认用本站根地址。
- **密钥别提交到公开仓库**，各店自己填自己的。

另外两件事（本来就是中文部署要做的）：

1. **价格表按人民币填**：金额换时长走 `PricingRates` 数据库价格区间，
   原表是菲律宾比索（₱），部署到国内店要把价格改成人民币金额。
2. **投币机页引用脚本**：在 `BNetVendoMachine.aspx` 里、其他 Vendo 脚本后面加一行
   （`.aspx` 页本身不在本源码仓库里，它在部署仓库 `BNet.Cafe.Timer` 中）：

```html
<script src="Assets/Vendo/WeChatPay.js"></script>
```

## 付款流程（代码层面）

1. 顾客在投币机页点右下角「微信扫码支付」，选一台电脑、选金额
   （金额档位 5/10/20/30/50/100 元，时长由 `CalculateDurationFromAmountHandler` 实时算出）。
2. `WeChatPay.js` 调 `CreateWeChatPayOrderHandler` 下单，拿到 `codeUrl`，
   用 `api.qrserver.com` 画成二维码展示，同时开始 2.5 秒轮询查单（5 分钟过期）。
3. 顾客微信扫码付款后，轮询到 `trade_state=SUCCESS`：
   - 调 `CreateRentalHandler.ashx` 建一条租用记录（记账用，和会员登录走同一接口）；
   - 调已有的 `sendTextMessageToPC(pc, JSON)` 经 `/ws/server`（opcode 0x02）把
     `{ userId: "Guest / Walk-in", duration, amount }` 发给对应电脑；
     客户端 `MainForm.HandleIncomingTextMessage` 收到后建本地计时并 `UnlockScreen()`，
     和投币成功后的解锁完全一样。
4. 若解锁指令发不出去（投币机与服务器的 WebSocket 断了），页面会明确提示
   “已收款，但解锁指令没发出去，请联系网管手动开卡”，钱不会白扣。

## 为什么不用微信回调

微信支付成功后会往 `notify_url` 推一条回调，但网吧服务器在局域网（192.168.x.x），
微信推不进来。所以这里用**服务端主动轮询** `orderquery` 查单，不需要公网地址、
不需要内网穿透，服务器能访问 `api.mch.weixin.qq.com` 就行。

## 待验证（需在 Windows 上编译部署后实测）

- Visual Studio 打开 `BNet.Cafe.sln` 能正常编译（本机是 Linux，没有 .NET Framework 4.8，
  无法在此编译验证）。
- 真实商户号下单、扫码、到账、解锁全流程。
- `BNetVendoMachine.aspx.cs`（投币机页的后台代码）不在开源仓库里，只有编译好的 DLL，
  所以本次改动刻意**没有动**投币机页的后台逻辑，只加了新接口 + 新 JS；
  部署时把 `WeChatPay.js` 引用加进 `.aspx` 即可。
