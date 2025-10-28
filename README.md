# 📘 GiWiFi 校园网自动登录脚本

一个兼容 BusyBox / OpenWrt / Linux 的纯 Shell 自动登录脚本，支持加密认证、设备自动绑定、错误重试等功能。

---

## ✨ 功能特点

* ✅ 自动提取登录页参数（iv、sign、pid、vlan）
* 🔐 本地 AES-128-CBC 加密登录请求
* 🔁 支持设备自动绑定与重试逻辑（`isRebind`、`reBind`）
* 🧩 纯 Shell 实现，无 Python、Node 依赖
* 🧱 完全兼容 OpenWrt / BusyBox 环境
* 📜 详细日志输出，可用于调试

---

## 🧰 环境依赖

在使用前，请确保系统已安装以下命令：

```bash
which curl openssl xxd hexdump od
```

脚本会自动检测可用命令（优先使用 `hexdump` 或 `xxd`）。

### OpenWrt 用户

可以通过以下命令安装依赖：

```bash
opkg update
opkg install curl openssl-util xxd
```

---

## 🚀 使用方法

将脚本放入 `/etc/giwifi-lan.sh`，并赋予可执行权限：

```bash
chmod +x /etc/giwifi-lan.sh
```

执行命令：

```bash
/etc/giwifi-lan.sh <手机号> <密码> <网关IP>
```

示例：

```bash
/etc/giwifi-lan.sh 19120486918 mypassword 192.168.99.2(GKD网关)
```

### 🧠 参数说明

| 参数       | 说明                  |
| -------- | ------------------- |
| `<手机号>`  | GiWiFi 登录账号（通常为手机号） |
| `<密码>`   | 登录密码                |
| `<网关IP>` | 登录页 IP，一般为校园网认证页面地址 |

> 默认 `USERIP` 固定为 `10.12.19.78`，可在脚本内修改。

---

## ⚙️ 开机自动执行

若希望每次启动路由器时自动登录，可在 `/etc/rc.local` 中添加：

```bash
/etc/giwifi-lan.sh 19120486918 mypassword 192.168.99.2 &
exit 0
```

也可以使用 OpenWrt 启动项设置：

```bash
uci set system.@system[0].startup='/etc/giwifi-lan.sh 19120486918 mypassword 192.168.99.2 &'
uci commit system
```

---

## 🧩 日志与调试

脚本会在执行时输出详细日志，例如：

```
[2025-10-28 14:22:15] [giwifi-lan.sh] - fetching login page: http://192.168.99.2/gportal/web/login?wlanuserip=10.12.19.78&wlanacname=GKDX
[2025-10-28 14:22:16] [giwifi-lan.sh] - extracted iv: 1234567890abcdef, sign: xxxxx, pid: 1, portalId: 2, vlan: 3
[2025-10-28 14:22:18] [giwifi-lan.sh] - ✅ 登录成功
```

调试模式：

```bash
sh -x /etc/giwifi-lan.sh <账号> <密码> <网关IP>
```

响应结果会保存到：

```
/tmp/giwifi_last_resp.json
```

---

## 🧠 常见问题 (FAQ)

### ❓ 登录页无法解析 IV

* 登录页 HTML 结构可能更新，尝试访问 `http://<portal_ip>/gportal/web/login` 查看源码是否含有 `id="iv"`。
* 若字段名称不同，请修改脚本中的 `sed` 解析部分。

### ❓ resultCode=2（设备已绑定）

* 脚本已内置自动解绑逻辑（`isRebind`、`reBind`），等待数秒后会自动重新绑定。

### ❓ OpenSSL 报错

* 检查 OpenSSL 是否支持 `enc` 模块。
* 可运行 `openssl enc -h` 查看支持的算法。

---

## 🪶 文件结构

```
/etc/
 ├── giwifi-lan.sh         # 主登录脚本
 ├── giwifi_last_resp.json # 最近一次返回数据
 └── login.html            # 登录页缓存
```

---

## 🧾 版权与许可

MIT License  © 2025  <Your Name>

可自由修改与分发，但请保留作者与来源说明。

---

## 🌐 项目地址（示例）

GitHub: [https://github.com/yourname/giwifi-lan-login](https://github.com/yourname/giwifi-lan-login)

---

> 💡 建议：若校园网认证逻辑有变化，可使用浏览器抓包工具重新确认前端请求参数结构（iv / sign / AES key 方式）。
