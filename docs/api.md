# Pocket Clipboard API (1.0.4)

Base URL: `https://hw.emptydust.com/pocket`

## 创建房间

`POST /api/session` → `201 {"code":"123456"}`。配对码是六位数字。

## 上传图片

`POST /api/room/{code}/image`，请求体为图片二进制，`Content-Type: image/jpeg` 或其他 `image/*` 类型。单张上限 8 MiB。
可选 `X-Sevenbu-Token` 指定本次 7bu 归档凭据；留空仍可接收，服务端不会将 Token 返回给电脑。
返回 `201 {"ok":true,"size":123456,"hostedStatus":"disabled"}`。
归档状态为 `disabled`、`pending`、`completed` 或 `failed`；归档失败不阻断图片接收。

## 接收流程

1. 每 2 秒请求 `GET /api/room/{code}/latest?meta=1`。返回 `image` 元数据（mime、size、at、hostedStatus、hostedUrl、hostedError）或 `image:null`，不含图片 data。
2. 保存响应的 `ETag`，后续元数据请求带 `If-None-Match`。无变化返回 `304`，响应体为空。图片、归档状态或图片过期发生变化时返回 `200` 和新的 ETag。
3. 仅当 `at` 大于已成功写入剪贴板的图片时间戳时，调用 `GET /api/room/{code}/latest` 下载完整数据。图片对象额外包含 Base64 `data`。解码或复制失败时不要更新接收游标或元数据 ETag，应重试。
4. 同一张图片的归档状态更新只更新界面，不重复下载或覆盖剪贴板。

旧版不带条件头的 `latest` 和 `latest?meta=1` 调用仍兼容。客户端刷新配对码时应取消旧请求并丢弃旧会话回调。遇到 `404` 应重新配对；网络或 `503` 错误采用指数退避（最长 30 秒）。

## 事件流

`GET /api/room/{code}/events` 建立 SSE 连接。新图片或归档状态变化发送 `event: image` 和元数据，服务端约每 25 秒发送注释心跳。连接断开后需重连；缓慢且积压的连接会被关闭。

## 生命周期与容量

- 房间在无请求且无事件流连接 30 分钟后清理。
- 图片在上传后 30 分钟独立过期，即使电脑持续轮询，也会释放图片数据；配对仍活动时返回 `image:null`。
- 默认最多 512 个房间；图片 Base64 常驻缓冲区合计 64 MiB；同时上传 4 个、归档 4 个、完整图片下载 8 个；事件流每房间 8 个、合计 128 个。
- 图片超限返回 `413`，容量满返回 `503`。归档容量满时仍接收图片，`hostedStatus=failed`，可继续使用电脑剪贴板。
- 以上是应用资源限额，不等同于进程 RSS 上限；正在传输的数据、解码和运行时本身另占内存。

服务重启会清空房间；macOS 客户端会自动生成新配对码，手机需使用新码。
