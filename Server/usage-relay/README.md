# 森空间额度中转

这是一个单用户、单实例的额度快照中转服务。它只保存最近一次 `usage-widget-v1.json`，没有账号管理、文件列表、任意文件下载或执行命令的接口。它不连接 Codex、不读取 Codex 登录文件，也不负责采集额度。

Mac 助手通过 HTTPS 上传脱敏记录；手机 App 和小组件通过 HTTPS 读取同一记录。手机只持有读取密钥，Mac 发布端只持有写入密钥。不要向这里发送 Codex 登录凭据、DSM 密码或原始接口响应。

## 接口契约

| 请求 | 鉴权 | 结果 |
| --- | --- | --- |
| `GET /health` | 无 | `200 {"status":"ok"}`，只表示进程可用 |
| `GET /v1/usage` | `Authorization: Bearer <readToken>` | `200` 返回快照；尚无记录或存储异常为 `503` |
| `PUT /v1/usage` | `Authorization: Bearer <writeToken>` | `200 {"ok":true}`；旧记录或同时间不同内容为 `409` |

PUT 需要 `Content-Type: application/json` 和准确的 `Content-Length`。不接受 chunked、压缩请求或 `Expect: 100-continue`。相同采集时间且内容相同的重复上传返回 `200`，不会更新记录的采集时间或文件时间。

两个密钥必须各为 **64 位小写十六进制**、内容不同，由 `secrets.token_hex(32)` 生成。密钥不能互换，也不能放进 URL。鉴权失败返回 `401`，结构不正确返回 `400`，超出大小限制返回 `413`。其他路径返回 `404`，其他方法返回 `405`。不提供 CORS；带 Origin、Referer 或跨站 Fetch Metadata 的请求会被拒绝。

快照使用 `CalendarWidgetShared/UsageWidgetData.swift` 的版本 1 协议：

```json
{
  "version": 1,
  "fetchedAt": 1800000000,
  "validUntil": 1800000900,
  "status": "ready",
  "windows": [
    {
      "id": "codex:primary",
      "label": "Codex · 5 小时",
      "usedPercent": 25,
      "windowMinutes": 300,
      "resetsAt": 1800003600
    }
  ]
}
```

示例日期仅说明结构，不可作为真实额度上传。规则如下：

- 请求体最大 64 KiB；最多 64 个窗口；ID 最长 160 字符、label 最长 120 字符，不含控制字符。
- 只接受表中结构的字段；额外的账号、邮箱、token 等字段会使整个请求失败。省略的可选窗口字段会规范化为 `null`。
- 日期为 Unix 秒，必须有限、正数且不晚于 `253402300799`。`fetchedAt` 不得晚于服务器当前时间；Mac 和 VPS 应开启系统时钟同步。
- `validUntil` 必须处于 `fetchedAt ... fetchedAt + 900`；服务不会延长有效期，也不会在额度重置时自行生成 100% 剩余量。
- 百分比为 `0 ... 100` 或 `null`；分钟数为正整数或 `null`；`resetsAt` 为有效日期或 `null`。
- `status` 为 `ready`、`notConnected` 或 `unavailable`；后两者必须没有窗口。
- 过期但结构合法的记录仍可读取，采集时间保持原样，由手机显示「待更新」。服务没有历史记录接口。

## 本地检查

只需 Python 3.9+ 标准库，不安装第三方依赖：

```sh
python3 Server/usage-relay/test_relay.py
```

测试只使用临时文件、固定测试密钥和本机临时端口，不连接 VPS 或真实账号。

## 部署到现有 VPS

以下是部署步骤示例，不会由 App 自动执行。将本目录复制到 VPS 的独立目录，避免覆盖现有站点或服务配置。

1. 创建服务器配置，生成密钥而不打印它们。容器使用 UID/GID `10001`；在 VPS 管理员 shell 执行：

   ```sh
   install -d -m 700 -o 10001 -g 10001 /opt/mori-usage-relay
   python3 - <<'PY'
   import json, os, secrets
   path = '/opt/mori-usage-relay/tokens.json'
   fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
   with os.fdopen(fd, 'w') as handle:
       json.dump({'version': 1, 'readToken': secrets.token_hex(32), 'writeToken': secrets.token_hex(32)}, handle)
   os.chown(path, 10001, 10001)
   PY
   ```

   `O_EXCL` 会保护已有配置，不会在重复执行时替换现有密钥。配置文件必须由容器 UID 持有，权限为 `0600`。将读取密钥仅配置给手机端，写入密钥仅配置给 Mac 发布端；不要把服务器完整配置传给手机。

2. 在本目录构建镜像并运行。端口只发布到 VPS 的 loopback，外网通过下一步的 HTTPS 反向代理进入：

   ```sh
   docker build -t mori-usage-relay:1 .
   docker volume create mori-usage-data
   docker run -d --name mori-usage-relay --restart unless-stopped \
     --read-only --cap-drop ALL --security-opt no-new-privileges \
     --pids-limit 64 --memory 128m --cpus 0.5 \
     -p 127.0.0.1:48764:48764 \
     --mount type=volume,source=mori-usage-data,target=/data \
     --mount type=bind,source=/opt/mori-usage-relay/tokens.json,target=/run/secrets/usage.json,readonly \
     mori-usage-relay:1
   ```

   镜像内为非 root 用户，根文件系统只读，仅 `/data` volume 保存最新记录。不要让多个实例同时挂载并写入同一数据 volume。升级时替换容器并保留配置和 volume。

3. 在现有、使用有效公信证书的 HTTPS 站点中加入独立路径。例如 Nginx 的现有 TLS `server` 块内：

   ```nginx
   location /mori-usage/ {
       client_max_body_size 64k;
       client_body_timeout 5s;
       proxy_request_buffering on;
       proxy_connect_timeout 3s;
       proxy_send_timeout 10s;
       proxy_read_timeout 10s;
       proxy_set_header Host $host;
       proxy_set_header Authorization $http_authorization;
       proxy_pass http://127.0.0.1:48764/;
       access_log off;
   }
   ```

   末尾 `/` 会去掉 `/mori-usage/` 前缀。客户端 `baseURL` 为 `https://你的域名/mori-usage`，并追加 `/v1/usage`；不要把 `/v1/usage` 也填进 baseURL。反向代理必须保留 Authorization，不添加 CORS、不记录请求头或请求体，不把此路径重定向到登录页。不要将 HTTP 48764 端口直接开放到公网。

4. 检查服务。以下请求不需要密钥，也不会显示额度：

   ```sh
   curl --fail --max-time 3 http://127.0.0.1:48764/health
   ```

   再检查 HTTPS 站点的 `/mori-usage/health`。最后由 Mac 发布端上传一次真实脱敏快照，再从手机网络读取；健康检查成功不代表额度上传和手机同步已经完成。

没有可用域名时，可使用公信 IP 证书，在独立 Nginx HTTPS `8443` 入口提供 `/mori-usage/`，保留原有 `443` 路由。客户端 `baseURL` 使用 `https://<公网IPv4>:8443/mori-usage`；证书的 IP SAN 必须覆盖该地址。后端仍只发布到 `127.0.0.1:48764`，保留标准证书与主机名校验。

采用 Let's Encrypt `shortlived` IP 证书时，可使用现有 acme.sh 账号，由每日 cron 检查并按两日续期配置轮换。保留 ACME 验证路径，并配置证书安装与重载 hook：将新证书安装到 Nginx 实际引用的位置，通过 `nginx -t` 后重载 Nginx。仅生成新证书或存在 cron 条目，不代表公网入口已经使用新证书。

续期后检查外部 `8443` 入口实际提供的证书有效期，并使用标准信任校验请求 `/mori-usage/health`。Docker 的 healthy 状态只验证内部后端，不能替代公网证书、续期和额度同步检查。

手机配对文件为 `{ "version": 1, "baseURL": "https://你的域名/mori-usage", "readToken": "..." }`；Mac 发布端私有配置为同样结构但字段是 `writeToken`。它们与服务器的双密钥配置是不同文件。不要把这些文件提交到 Git。

不使用 Docker 时可运行：

```sh
python3 -B -E -s relay.py --data-dir /绝对路径/data --config /绝对路径/tokens.json
```

默认监听 `127.0.0.1:48764`。只有容器内部场景才使用 `--bind 0.0.0.0`。也支持通过 `MORI_USAGE_READ_TOKEN` 与 `MORI_USAGE_WRITE_TOKEN` 环境变量提供密钥；不要同时指定 `--config`，推荐使用只读挂载配置以免部署工具展示环境变量。

## 运行与撤销

服务最多处理 8 个并发连接，header 总计 16 KiB、总读取时间 2 秒，body 总读取时间 5 秒；每分钟最多 120 个通过鉴权的读取请求、60 个写入请求。请求不会触发 Codex 采集。响应禁止缓存，访问日志关闭，进程错误仅输出固定类别。

记录以 `0600` 原子替换并 fsync。上传失败保留旧文件。收到 SIGTERM 后关闭请求连接并等待线程退出，不生成新记录。文件损坏时读取返回 `503`，不会把未知内容送给手机，也不会悄悄覆盖无法校验的旧文件。

更换密钥后需重启容器，并更新对应设备配置；读取密钥泄露时只需轮换读取密钥。停止或删除容器不会清除数据 volume。服务更新依赖 Mac 采集和网络连接，手机小组件刷新仍由 WidgetKit 调度，不能保证秒级或固定间隔刷新。
