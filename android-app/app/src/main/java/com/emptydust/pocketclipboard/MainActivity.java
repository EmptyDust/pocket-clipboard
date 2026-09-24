package com.emptydust.pocketclipboard;

import android.Manifest;
import android.app.Activity;
import android.content.ContentValues;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.os.Build;
import android.provider.MediaStore;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.view.Gravity;
import android.view.View;
import android.content.SharedPreferences;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.Switch;
import android.widget.TextView;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.text.SimpleDateFormat;
import java.util.Date;
import org.json.JSONObject;
import java.security.KeyStore;
import java.util.Base64;
import java.util.Locale;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

public class MainActivity extends Activity {
    private static final String API_BASE = "https://hw.emptydust.com/pocket";
    private static final int CAMERA_REQUEST = 42;
    private static final int GALLERY_REQUEST = 43;
    private static final int GALLERY_PERMISSION_REQUEST = 44;
    private EditText codeInput;
    private EditText tokenInput;
    private Switch saveLocalSwitch;
    private TextView status;
    private ImageView preview;
    private Uri photoUri;
    private boolean deleteCapturedPhotoAfterSend;
    private boolean capturedPhotoPending;
    private SharedPreferences preferences;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        preferences = getSharedPreferences("pocket_clipboard", MODE_PRIVATE);
        buildUi();
    }

    private void buildUi() {
        int pad = dp(24);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL); root.setPadding(pad, dp(32), pad, pad); root.setBackgroundColor(0xfff4f1ea);

        TextView title = text("Pocket Clipboard", 28, 0xff1e2422);
        root.addView(title, new LinearLayout.LayoutParams(-1, -2));
        TextView subtitle = text("手机拍照，直接发送到电脑剪贴板", 16, 0xff737a75);
        LinearLayout.LayoutParams subParams = new LinearLayout.LayoutParams(-1, -2); subParams.topMargin = dp(8); root.addView(subtitle, subParams);

        codeInput = new EditText(this); codeInput.setHint("输入电脑上的六位配对码"); codeInput.setInputType(2); codeInput.setSingleLine(); codeInput.setTextSize(20); codeInput.setGravity(Gravity.CENTER); codeInput.setPadding(dp(12), 0, dp(12), 0);
        codeInput.setText(preferences.getString("pair_code", ""));
        codeInput.setSelectAllOnFocus(true);
        codeInput.setOnFocusChangeListener((view, focused) -> { if (!focused) saveCode(); });
        LinearLayout.LayoutParams codeParams = new LinearLayout.LayoutParams(-1, dp(58)); codeParams.topMargin = dp(30); root.addView(codeInput, codeParams);

        tokenInput = new EditText(this); tokenInput.setHint("可选：7bu Token（仅本机加密保存）"); tokenInput.setSingleLine(); tokenInput.setTextSize(14); tokenInput.setInputType(0x81); tokenInput.setText(loadToken()); tokenInput.setOnFocusChangeListener((view, focused) -> { if (!focused) saveToken(); });
        LinearLayout.LayoutParams tokenParams = new LinearLayout.LayoutParams(-1, dp(48)); tokenParams.topMargin = dp(10); root.addView(tokenInput, tokenParams);

        saveLocalSwitch = new Switch(this); saveLocalSwitch.setText("保存拍摄原图到手机相册"); saveLocalSwitch.setTextSize(14); saveLocalSwitch.setChecked(preferences.getBoolean("save_local_photo", true)); saveLocalSwitch.setOnCheckedChangeListener((button, checked) -> preferences.edit().putBoolean("save_local_photo", checked).apply());
        LinearLayout.LayoutParams saveParams = new LinearLayout.LayoutParams(-1, dp(44)); saveParams.topMargin = dp(4); root.addView(saveLocalSwitch, saveParams);

        LinearLayout actions = new LinearLayout(this); actions.setOrientation(LinearLayout.HORIZONTAL); actions.setGravity(Gravity.CENTER); actions.setWeightSum(2);
        Button camera = new Button(this); camera.setText("拍照并发送"); camera.setTextSize(16); camera.setOnClickListener(v -> takePhoto());
        Button gallery = new Button(this); gallery.setText("从相册选择"); gallery.setTextSize(16); gallery.setOnClickListener(v -> choosePhoto());
        actions.addView(camera, new LinearLayout.LayoutParams(0, dp(58), 1)); actions.addView(gallery, new LinearLayout.LayoutParams(0, dp(58), 1));
        LinearLayout.LayoutParams buttonParams = new LinearLayout.LayoutParams(-1, dp(58)); buttonParams.topMargin = dp(16); root.addView(actions, buttonParams);

        status = text("输入配对码后即可开始", 15, 0xff737a75); status.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams statusParams = new LinearLayout.LayoutParams(-1, -2); statusParams.topMargin = dp(14); root.addView(status, statusParams);
        preview = new ImageView(this); preview.setScaleType(ImageView.ScaleType.CENTER_INSIDE); preview.setBackgroundColor(0xfffaf8f2);
        LinearLayout.LayoutParams previewParams = new LinearLayout.LayoutParams(-1, 0, 1); previewParams.topMargin = dp(24); root.addView(preview, previewParams);
        setContentView(root);
    }

    private void takePhoto() {
        String code = codeInput.getText().toString().trim();
        if (!code.matches("\\d{6}")) { status.setText("请输入六位数字配对码"); return; }
        saveCode();
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) { requestPermissions(new String[]{Manifest.permission.CAMERA}, CAMERA_REQUEST); return; }
        boolean saveLocal = saveLocalSwitch.isChecked();
        deleteCapturedPhotoAfterSend = !saveLocal;
        preferences.edit().putBoolean("save_local_photo", saveLocal).apply();
        ContentValues values = new ContentValues(); values.put(MediaStore.Images.Media.DISPLAY_NAME, "PocketClipboard_" + timestamp() + ".jpg"); values.put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg");
        if (Build.VERSION.SDK_INT >= 29) { values.put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/PocketClipboard"); values.put(MediaStore.Images.Media.IS_PENDING, 1); }
        photoUri = getContentResolver().insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
        if (photoUri == null) { status.setText("无法创建照片文件"); return; }
        capturedPhotoPending = true;
        Intent intent = new Intent(MediaStore.ACTION_IMAGE_CAPTURE); intent.putExtra(MediaStore.EXTRA_OUTPUT, photoUri); startActivityForResult(intent, CAMERA_REQUEST);
    }

    private void choosePhoto() {
        String code = codeInput.getText().toString().trim();
        if (!code.matches("\\d{6}")) { status.setText("请输入六位数字配对码"); return; }
        deleteCapturedPhotoAfterSend = false;
        saveCode();
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.READ_MEDIA_IMAGES}, GALLERY_PERMISSION_REQUEST); return;
        }
        if (Build.VERSION.SDK_INT < 33 && checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.READ_EXTERNAL_STORAGE}, GALLERY_PERMISSION_REQUEST); return;
        }
        openGallery();
    }

    private void openGallery() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.setType("image/*"); intent.addCategory(Intent.CATEGORY_OPENABLE);
        startActivityForResult(intent, GALLERY_REQUEST);
    }

    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == CAMERA_REQUEST && results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) takePhoto();
        if (request == GALLERY_PERMISSION_REQUEST && results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) openGallery();
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == CAMERA_REQUEST && result != RESULT_OK) { deleteCapturedPhoto(); return; }
        if (request == GALLERY_REQUEST && result == RESULT_OK && data != null && data.getData() != null) photoUri = data.getData();
        if ((request != CAMERA_REQUEST && request != GALLERY_REQUEST) || result != RESULT_OK || photoUri == null) return;
        if (request == CAMERA_REQUEST && saveLocalSwitch.isChecked()) publishCapturedPhoto();
        status.setText("正在压缩并发送…");
        saveToken();
        new Thread(() -> { try { byte[] bytes = compressPhoto(); String hostedStatus = upload(bytes); runOnUiThread(() -> { status.setText(uploadStatusText(hostedStatus)); preview.setImageURI(photoUri); deleteCapturedPhoto(); }); } catch (Exception e) { deleteCapturedPhoto(); runOnUiThread(() -> status.setText("发送失败：" + e.getMessage())); } }).start();
    }

    private String timestamp() { return new SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(new Date()); }

    private void publishCapturedPhoto() { if (Build.VERSION.SDK_INT >= 29 && photoUri != null) { ContentValues values = new ContentValues(); values.put(MediaStore.Images.Media.IS_PENDING, 0); getContentResolver().update(photoUri, values, null, null); } capturedPhotoPending = false; }

    private void deleteCapturedPhoto() { if (photoUri != null && (capturedPhotoPending || deleteCapturedPhotoAfterSend)) { getContentResolver().delete(photoUri, null, null); photoUri = null; capturedPhotoPending = false; deleteCapturedPhotoAfterSend = false; } }

    private byte[] compressPhoto() throws Exception {
        Bitmap source; try (InputStream input = getContentResolver().openInputStream(photoUri)) { source = BitmapFactory.decodeStream(input); }
        if (source == null) throw new Exception("无法读取照片");
        int max = 2200; float scale = Math.min(1f, max / (float)Math.max(source.getWidth(), source.getHeight()));
        Bitmap scaled = Bitmap.createScaledBitmap(source, Math.max(1, Math.round(source.getWidth() * scale)), Math.max(1, Math.round(source.getHeight() * scale)), true);
        ByteArrayOutputStream output = new ByteArrayOutputStream(); scaled.compress(Bitmap.CompressFormat.JPEG, 82, output); source.recycle(); if (scaled != source) scaled.recycle(); return output.toByteArray();
    }

    private String upload(byte[] bytes) throws Exception {
        String code = codeInput.getText().toString().trim(); URL url = new URL(API_BASE + "/api/room/" + code + "/image"); HttpURLConnection connection = (HttpURLConnection) url.openConnection(); connection.setRequestMethod("POST"); connection.setDoOutput(true); connection.setConnectTimeout(15000); connection.setReadTimeout(30000); connection.setRequestProperty("Content-Type", "image/jpeg"); String token = loadToken(); if (!token.isEmpty()) connection.setRequestProperty("X-Sevenbu-Token", token); connection.setFixedLengthStreamingMode(bytes.length);
        try (OutputStream output = connection.getOutputStream()) { output.write(bytes); }
        int response = connection.getResponseCode();
        InputStream input = response >= 200 && response < 300 ? connection.getInputStream() : connection.getErrorStream();
        ByteArrayOutputStream body = new ByteArrayOutputStream(); if (input != null) { byte[] buffer = new byte[1024]; int count; while ((count = input.read(buffer)) != -1) body.write(buffer, 0, count); input.close(); }
        if (response < 200 || response >= 300) throw new Exception("服务器返回 " + response);
        String hostedStatus = "disabled"; try { hostedStatus = new JSONObject(body.toString("UTF-8")).optString("hostedStatus", hostedStatus); } catch (Exception ignored) { }
        connection.disconnect(); return hostedStatus;
    }

    private String uploadStatusText(String hostedStatus) {
        if ("pending".equals(hostedStatus)) return "已发送到电脑，图床归档中…";
        if ("completed".equals(hostedStatus)) return "已发送到电脑，图床已归档";
        if ("failed".equals(hostedStatus)) return "已发送到电脑，但图床归档失败";
        return "已发送到电脑";
    }

    private void saveToken() { if (tokenInput == null) return; try { String value = tokenInput.getText().toString().trim(); if (value.isEmpty()) { preferences.edit().remove("sevenbu_token").remove("sevenbu_token_iv").apply(); return; } Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, getTokenKey()); byte[] encrypted = cipher.doFinal(value.getBytes("UTF-8")); preferences.edit().putString("sevenbu_token", Base64.getEncoder().encodeToString(encrypted)).putString("sevenbu_token_iv", Base64.getEncoder().encodeToString(cipher.getIV())).apply(); } catch (Exception ignored) { }
    }

    private String loadToken() { try { String encrypted = preferences.getString("sevenbu_token", ""); String iv = preferences.getString("sevenbu_token_iv", ""); if (encrypted.isEmpty() || iv.isEmpty()) return ""; Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.DECRYPT_MODE, getTokenKey(), new GCMParameterSpec(128, Base64.getDecoder().decode(iv))); return new String(cipher.doFinal(Base64.getDecoder().decode(encrypted)), "UTF-8"); } catch (Exception ignored) { return ""; } }

    private SecretKey getTokenKey() throws Exception { KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null); String alias = "pocket_clipboard_sevenbu"; if (!store.containsAlias(alias)) { KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore"); generator.init(new KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build()); generator.generateKey(); } return (SecretKey) store.getKey(alias, null); }

    private TextView text(String value, int size, int color) { TextView view = new TextView(this); view.setText(value); view.setTextSize(size); view.setTextColor(color); return view; }
    private void saveCode() { if (codeInput != null) preferences.edit().putString("pair_code", codeInput.getText().toString().trim()).apply(); }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
}
