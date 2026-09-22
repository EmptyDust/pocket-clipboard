# Pocket Clipboard API

Base URL: `https://hw.emptydust.com/pocket`

## 创建房间

`POST /api/session`

返回六位数字配对码：

```json
{"code":"123456"}
```

## 上传图片

`POST /api/room/{code}/image`

请求体为图片二进制，必须设置 `Content-Type: image/jpeg`、`image/png` 等图片类型，单张图片最大 8 MB。

成功返回：

```json
{"ok":true,"size":123456}
```

## 获取最新图片

`GET /api/room/{code}/latest`

返回最新图片的 Base64 数据及 `mime`、`size`、`at` 元数据。`GET /api/room/{code}/latest?meta=1` 只返回元数据。

## 事件流

`GET /api/room/{code}/events`

建立 Server-Sent Events 连接。新图片到达时发送 `event: image`，事件数据包含图片元数据，客户端随后读取 `latest` 获取图片内容。

## 生命周期

房间和图片只保存在服务进程内存中。房间在 30 分钟无活动且没有客户端连接时自动清理，不做永久图片存储。
