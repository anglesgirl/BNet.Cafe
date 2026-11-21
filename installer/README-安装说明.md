# BNet Cafe 一键安装说明（给网吧老板）

## 装之前

- 这台电脑就是**收银台那台服务器**：网站、数据库、WebSocket 都装在这台上，平时开着别关。
- 系统要求：**Windows 10 / 11**（专业版用完整 IIS，家庭版自动改用 IIS Express，都能装）或 Windows Server。
- 安装时需要**管理员权限**和联网（只在第一次装 .NET 时联网，之后不用）。
- 安装大约 3–5 分钟，装完自动打开管理后台。

## 安装

1. 双击 `BNetCafe-Setup-1.0.0.exe`，点“是”允许管理员权限。
2. 一路“下一步”，安装目录默认 `C:\BNetCafe`，不用改。
3. 等它跑完（中间会装 MariaDB 数据库、开 IIS 网站，不用管）。
4. 装完自动打开管理后台 `http://localhost:2000/BNet.Cafe.Server/Login.aspx`。

## 装完先做的三件事

1. **注册管理员账号**：打开管理后台，注册第一个账号（就是老板账号），记好邮箱和密码。
2. **改价格**：管理后台 → 价格设置，把菲律宾比索的价格改成人民币（比如 5 元 1 小时，按自己店里定）。
3. **填微信支付**：管理后台没有微信设置入口，直接改文件 `C:\BNetCafe\Server\Web.config`，找到 `WeChatPay_AppId` / `WeChatPay_MchId` / `WeChatPay_ApiKey` 三行，填自己店的微信商户号（AppId、商户号、API 密钥），保存后**重启网站**（任务管理器里重启 IIS，或重启电脑）。没有商户号可以先不填，投币流程和页面都能先测。

## 客户机怎么上机

- 每台客户机装 `C:\BNetCafe\Client\BNet.Cafe.Client.exe`（连同目录里的 dll 一起拷过去），双击运行，锁屏界面就出来了。
- 也可以从管理后台的下载页下载客户端。
- 客户扫码付款后，服务器通过 WebSocket 自动给对应电脑解锁，不用人工操作。

## 平时用

- 开机后什么都不用点：网站（IIS）、数据库（MariaDB）、WebSocket 都是开机自启。
- 管理后台：桌面上的“BNet Cafe 管理后台”快捷方式，或浏览器打开 `http://localhost:2000/BNet.Cafe.Server/`。
- 局域网里其他电脑也能打开管理后台：把 `localhost` 换成这台服务器的局域网 IP（比如 `http://192.168.1.100:2000/BNet.Cafe.Server/`）。

## 出问题先看这里

- 装完打不开管理后台：看 `C:\BNetCafe\Setup-Log.txt`（安装日志），最后一行会写原因；常见是 IIS 没开起来，重启电脑再试一次。
- 数据库密码：`C:\BNetCafe\数据库密码.txt`（安装器自动生成的 MariaDB root 密码，平时用不上，直连数据库才要）。
- WebSocket 没启动（扫码付了钱电脑不解锁）：打开任务管理器 → 服务，看 `BNetCafe WebSocket` 计划任务有没有跑；或手动双击 `C:\BNetCafe\WebSocket\Start-WebSocket.bat`。
- 彻底卸载：控制面板卸载 BNet Cafe（会停掉 WebSocket 自启；IIS 网站和数据库会保留，免得误删营业数据；要彻底清掉，卸载后再手动删 `C:\BNetCafe` 和 IIS 里的 BNetCafe 网站、MariaDB 服务）。
