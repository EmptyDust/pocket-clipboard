# Pocket Clipboard Android

这是手机原生 Android 客户端。它使用系统相机拍照或从相册选择图片，将图片压缩为最长边 2200 像素的 JPEG，然后上传到电脑端 macOS 接收器显示的六位配对码。应用会申请相机和相册读取权限。拍照时会向系统相机明确授予临时输出文件的读写权限，兼容部分不会自动继承 URI 权限的相机应用。

可在配对码下方填写 7bu Token。Token 使用 Android Keystore 加密后保存在本机，只会通过 HTTPS 发送给 Pocket Clipboard 服务端，用于本次图片的图床归档，不会发送给电脑端。Token 留空时仍可正常发送到电脑，只是不归档到图床。

“保存拍摄原图到手机相册”开关默认开启。开启时，照片会保存为 `PocketClipboard_yyyyMMdd_HHmmss_SSS.jpg`；关闭时，照片只用于本次上传，发送完成或失败后会自动删除，不会在相册留下文件。

用 Android Studio 打开 `android-app/`，连接 Android 手机后运行，或使用 `Build > Build APK(s)` 生成 APK。配对码会保存在本地应用设置中，应用切到后台或重新打开后仍会保留。
