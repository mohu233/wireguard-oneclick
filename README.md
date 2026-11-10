# WireGuard 一键部署包

给新 VPS 部署 WireGuard，生成两个独立客户端配置：

| 文件 | 用途 | 隧道地址 |
|---|---|---|
| `wg-router.conf` | 导入软路由 | 默认 `10.66.66.2/32` |
| `wg-test.conf` | 导入电脑或手机 WireGuard 测试 | 默认 `10.66.66.3/32` |

文件名可直接用于 Windows WireGuard。两份配置使用不同密钥，可以同时连接。每份配置仅供一台活动设备使用。

## Windows：把新服务器文件夹拖进去

1. 解压整个部署包。复制里面的 **新服务器模板** 文件夹，以新服务器 IP 命名。
2. 记事本打开该文件夹中的 `server.env`，填写 `SSH_HOST=你的新服务器IP` 并保存。其他参数通常不用改。
3. 将这个**服务器资料文件夹拖到 `一键部署.cmd` 上**。首次连接核对 SSH 指纹，输入 `yes`，再输入服务器 root 密码。输入密码时不显示字符，这是正常现象。

部署成功后，两份配置自动保存在该服务器资料文件夹的 **`output`** 目录中。目录权限限制为当前 Windows 用户和 SYSTEM。

也可以直接双击 `一键部署.cmd`，使用部署包根目录的 `server.env`；SSH_HOST 留空时会提示输入服务器 IP。需要 Windows 自带的 OpenSSH 客户端，无需安装 Python、Git 或 WSL。脚本不会修改本机的 AirCandy、WireGuard 或网卡配置。

**新增下一台服务器：** 再复制一份模板、填 IP、拖入即可。每个资料文件夹单独保存导出的配置。服务器密码不写入资料文件，也不上传到 GitHub。

## Linux：整个文件夹上传到服务器，运行 sh

把部署包上传到新 VPS。用 root 登录，在部署包目录中填写 `server.env` 的 `ENDPOINT=服务器公网IP`，然后执行：

```sh
sh deploy.sh server.env
```

脚本会自动转到 Bash。直接在服务器运行时，配置也会输出到部署包目录的 `output/`，服务器持久副本保存在 `/opt/office-wg/clients/`。

不要把 Windows 的 `.sh` 双击方式当成安装入口：Windows 使用 `一键部署.cmd`；服务器上使用上述 `sh` 命令。

## 服务器资料

`server.env` 是数据文件，不执行其中的命令。支持这些字段：

| 字段 | 默认值 / 说明 |
|---|---|
| `SSH_HOST` | Windows 入口连接的新服务器 IPv4 或域名 |
| `SSH_PORT` | `22` |
| `SSH_USER` | `root`；服务器安装需要 root 权限 |
| `SSH_IDENTITY_FILE` | 留空使用密码或已有 SSH 身份；也可填写本地私钥路径 |
| `ENDPOINT` | WireGuard 对外提供的公网 IPv4 或域名；Windows 下留空时使用 SSH_HOST |
| `WG_PORT` | `51820`，UDP |
| `VPN_SUBNET` | `10.66.66.0/24`；必须是不与服务器已有网络重叠的私有 /24 网段 |
| `DNS` | `1.1.1.1,9.9.9.9` |
| `MTU` | `1420`；可设置为 `1280`～`1420` |
| `WAN_INTERFACE` | `auto`，从默认路由识别；特殊拓扑可指定实际出口网卡 |

云服务器网卡若显示私网 IP，`ENDPOINT` 仍填写它的公网地址。云平台安全组需允许所选 UDP 端口入站；脚本只配置 VPS 内的防火墙，无法代替云平台安全组。

## 重复运行与现有服务器

同一服务器、同样参数再次运行时，保留现有密钥和服务器对端，只检查状态并重新导出两份客户端配置。不要用本包直接覆盖以前手工安装的服务；发现旧的部署或接口冲突时会停止并说明原因。

独立服务为 `office-wg.service`，接口为 `wg-office`，文件保存在 `/opt/office-wg/`。首次安装失败会尝试撤回本包新建的服务和规则；已安装的软件依赖会保留。不会清空系统防火墙，也不占用 UDP 443。

支持 systemd Linux，优先使用内核 WireGuard；CentOS 7 等旧内核采用官方 wireguard-go 用户态实现，需要可用的 `/dev/net/tun`。安装所需软件包、旧内核构建依赖需要服务器能访问软件源和官方源码站点。用户态构建所用源码版本与摘要固定在 `lib/install-runtime.sh`。

目前支持未运行 UFW 的 iptables 环境，以及使用 iptables 后端的 firewalld。遇到启用的 UFW 或 firewalld nftables 后端会停止，避免给出不实的成功结果。Alpine、OpenWrt 和不提供 systemd / TUN 的受限容器不是此 VPS 安装器的目标。

## 检查和重新导出

Windows PowerShell：

```powershell
# 仅检查本地资料格式，不连接服务器
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -ServerFolder "D:\新服务器资料" -ValidateOnly

# 连接服务器做预检，不部署
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -ServerFolder "D:\新服务器资料" -CheckOnly

# 从已由本包部署的服务器重新取回两份配置
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -ServerFolder "D:\新服务器资料" -ExportOnly
```

服务器检查：

```sh
sh deploy.sh --check server.env
systemctl status office-wg
wg show wg-office
journalctl -u office-wg -n 50 --no-pager
```

部署器会检查服务、接口、监听端口和服务器规则；实际可用性还需导入 `wg-test.conf` 后验证握手、DNS、出口 IP 和速度。导入软路由之后，仍需将相应 Wi-Fi 网络的路由和防火墙转发关联到该接口。

## 文件与验证

`deploy.sh` 为服务器安装器，`lib/install-runtime.sh` 安装系统依赖；`deploy.ps1` 和 `一键部署.cmd` 为 Windows 远程入口。`tests/` 提供离线测试，GitHub Actions 会验证 Linux Shell 和 Windows PowerShell 入口。

导出的 `.conf` 含私钥。Git 忽略输出目录、私钥和实际服务器资料；仓库只应包含空白模板和通用代码。
