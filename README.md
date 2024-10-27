# One-click-script
## _**简介一键安装脚本**_
- 建议开启bbr加速，可大幅加快节点reality和vmess节点的速度
- 无脑回车一键安装或者自定义安装
- 完全无需域名，使用自签证书部署hy2，（使用argo隧道支持vmess ws优选ip（理论上比普通优选ip更快））
- 支持修改reality端口号和域名，hysteria2端口号
- 无脑生成sing-box，clash-meta，v2rayN，nekoray等通用链接格式
- 支持warp，任意门，ss解锁流媒体
- 支持任意门中转
- 支持端口跳跃
## Debian ubuntu ... 一键脚本
```bash
bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/Ubuntu.sh)
```
## `Alpine`-script 一键脚本
```bash
apk add curl && apk add bash && bash <(curl -fsSL https://cfgithub.gw2333.workers.dev/https://github.com/mi1314cat/Alpine-script/raw/refs/heads/main/alpine.sh)
```

## **申请证书**
### Debian ubuntu ...ac证书
```bash
bash <(curl -fsSL https://github.com/mi1314cat/xary-core/raw/refs/heads/main/acme.sh)
```
### Alpine-ac证书
 ```bash
apk add curl && apk add bash && bash <(curl -fsSL https://github.com/mi1314cat/Alpine-script/raw/refs/heads/main/acme.sh)
```
## **_[xray](https://github.com/mi1314cat/xary-core)core_**
### xrayS- vmess+ws和sock5
```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/xrayS.sh)
```
### reality一键脚本

```bash
bash <(curl -Ls https://github.com/mi1314cat/xary-core/raw/refs/heads/main/reality_xray.sh)
```
## **_[sing-box](https://github.com/mi1314cat/sing-box-core)core_**
## _reality hysteria2二合一脚本_

```bash
bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh)
```

## **_[hysteria2](https://github.com/mi1314cat/hysteria2-core)_**
### _hysteria2 带面板脚本_
```bash
bash <(curl -fsSL https://github.com/mi1314cat/hysteria2-core/raw/refs/heads/main/hy2-panel.sh)
```
### _hysteria2 快速脚本_
```bash
bash <(curl -fsSL https://github.com/mi1314cat/hysteria2-core/raw/refs/heads/main/fast-hy2.sh)
```
## **_[infinite-nodes](https://github.com/mi1314cat/infiniteipv6) ipv6_**
### Debian ubuntu ... _ipv6无限节点 _ 
#### **`ipv6后缀要小于128`** Debian ubuntu ...
```bash
bash <(curl -fsSL https://github.com/mi1314cat/infiniteipv6/raw/refs/heads/main/infinite-nodes.sh)
```
