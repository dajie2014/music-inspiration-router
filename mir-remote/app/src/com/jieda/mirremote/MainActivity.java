package com.jieda.mirremote;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.DownloadManager;
import android.content.Context;
import android.content.DialogInterface;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.webkit.DownloadListener;
import android.webkit.URLUtil;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;

/**
 * MIR Remote —— 手机上的遥控镜子。
 *
 * 它只是一层壳：里面跑的是电脑上那个网页（出歌 → 看进度 → 拿歌拿谱）。
 * 壳负责三件事：
 *   1. 找对电脑的地址（先试出门那条，再试家里那条）
 *   2. 把网页里的「下载」接住，落到手机下载目录
 *   3. 连不上时给一句人话，不是一串报错
 */
public class MainActivity extends Activity {

    static final int C_BG = 0xFF0F1115;
    static final int C_TXT = 0xFFE8EAEF;
    static final int C_DIM = 0xFF8B93A5;
    static final int C_ACCENT = 0xFF4ADE80;

    // 两个地址都试：先出门那条（Tailscale，在家 WiFi 下也通）；
    // 万一把 Tailscale 关了，就落回家里这个。
    static final String[] CANDIDATES = {
            "http://100.110.118.100:7871",
            "http://192.168.31.99:7871",
    };

    WebView web;
    ProgressBar bar;
    LinearLayout errorBox;
    SharedPreferences sp;
    final Handler ui = new Handler(Looper.getMainLooper());
    boolean probing = false;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        sp = getSharedPreferences("mir", MODE_PRIVATE);
        setContentView(buildUi());
        startProbe(sp.getString("base", ""));
    }

    // ─────────────────────────── 界面 ───────────────────────────

    View buildUi() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(C_BG);

        web = new WebView(this);
        web.setBackgroundColor(C_BG);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setUseWideViewPort(true);
        s.setLoadWithOverviewMode(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, String url) {
                v.loadUrl(url);
                return true;
            }

            @Override
            public void onPageFinished(WebView v, String url) {
                bar.setVisibility(View.GONE);
            }
        });
        web.setDownloadListener(new DownloadListener() {
            @Override
            public void onDownloadStart(String url, String ua, String cd, String mime, long len) {
                download(url, cd, mime);
            }
        });
        root.addView(web, new FrameLayout.LayoutParams(-1, -1));

        bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        bar.setIndeterminate(true);
        bar.setIndeterminateTintList(ColorStateList.valueOf(C_ACCENT));
        FrameLayout.LayoutParams bp = new FrameLayout.LayoutParams(-1, dp(3));
        bp.gravity = Gravity.TOP;
        root.addView(bar, bp);

        // 连不上的时候出来：只说人话，给人一个「再试」和一个「换地址」
        errorBox = new LinearLayout(this);
        errorBox.setOrientation(LinearLayout.VERTICAL);
        errorBox.setGravity(Gravity.CENTER);
        errorBox.setPadding(dp(30), dp(30), dp(30), dp(30));
        errorBox.setVisibility(View.GONE);

        TextView title = new TextView(this);
        title.setText("连不上电脑");
        title.setTextColor(C_TXT);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 30);
        title.setGravity(Gravity.CENTER);
        errorBox.addView(title);

        TextView msg = new TextView(this);
        msg.setText("电脑开着吗？手机和电脑在同一个 WiFi 吗？\n\n"
                + "在外面用的话，手机上的 Tailscale 得开着。");
        msg.setTextColor(C_DIM);
        msg.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17);
        msg.setGravity(Gravity.CENTER);
        msg.setPadding(0, dp(18), 0, dp(30));
        errorBox.addView(msg);

        Button retry = new Button(this);
        retry.setText("再试一次");
        retry.setTextSize(TypedValue.COMPLEX_UNIT_SP, 19);
        retry.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                startProbe(sp.getString("base", ""));
            }
        });
        errorBox.addView(retry, new LinearLayout.LayoutParams(-1, dp(58)));

        Button change = new Button(this);
        change.setText("换一个地址");
        change.setTextSize(TypedValue.COMPLEX_UNIT_SP, 19);
        change.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                askAddress();
            }
        });
        errorBox.addView(change, new LinearLayout.LayoutParams(-1, dp(58)));

        root.addView(errorBox, new FrameLayout.LayoutParams(-1, -1));
        return root;
    }

    // ─────────────────────────── 找地址 ───────────────────────────

    static String norm(String raw) {
        if (raw == null) return null;
        String v = raw.trim();
        if (v.length() == 0) return null;
        if (!v.startsWith("http://") && !v.startsWith("https://")) v = "http://" + v;
        while (v.endsWith("/")) v = v.substring(0, v.length() - 1);
        return v;
    }

    void startProbe(final String saved) {
        if (probing) return;
        probing = true;
        errorBox.setVisibility(View.GONE);
        bar.setVisibility(View.VISIBLE);

        final ArrayList<String> list = new ArrayList<>();
        String first = norm(saved);
        if (first != null) list.add(first);
        for (String c : CANDIDATES) {
            String n = norm(c);
            if (n != null && !list.contains(n)) list.add(n);
        }

        new Thread(new Runnable() {
            @Override
            public void run() {
                for (final String base : list) {
                    if (ping(base + "/v1/info")) {
                        ui.post(new Runnable() {
                            @Override
                            public void run() {
                                probing = false;
                                sp.edit().putString("base", base).apply();
                                load(base);
                            }
                        });
                        return;
                    }
                }
                ui.post(new Runnable() {
                    @Override
                    public void run() {
                        probing = false;
                        bar.setVisibility(View.GONE);
                        errorBox.setVisibility(View.VISIBLE);
                    }
                });
            }
        }).start();
    }

    boolean ping(String url) {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(url).openConnection();
            c.setConnectTimeout(2500);
            c.setReadTimeout(2500);
            c.setRequestMethod("GET");
            return c.getResponseCode() == 200;
        } catch (Exception e) {
            return false;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    void load(String base) {
        bar.setVisibility(View.VISIBLE);
        errorBox.setVisibility(View.GONE);
        web.loadUrl(base + "/");
    }

    void askAddress() {
        final EditText et = new EditText(this);
        et.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        et.setText(sp.getString("base", CANDIDATES[0]));
        et.setHint("例如 192.168.31.99:7871");
        new AlertDialog.Builder(this)
                .setTitle("电脑的地址")
                .setView(et)
                .setPositiveButton("连这个", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int w) {
                        String v = norm(et.getText().toString());
                        if (v == null) {
                            Toast.makeText(MainActivity.this, "地址不能空着", Toast.LENGTH_SHORT).show();
                            return;
                        }
                        sp.edit().putString("base", v).apply();
                        startProbe(v);
                    }
                })
                .setNegativeButton("算了", null)
                .show();
    }

    // ─────────────────────────── 下载 ───────────────────────────

    void download(String url, String contentDisposition, String mime) {
        try {
            String name = URLUtil.guessFileName(url, contentDisposition, mime);
            DownloadManager.Request req = new DownloadManager.Request(Uri.parse(url));
            req.setTitle(name);
            req.setDescription("MIR Remote");
            req.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
            req.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name);
            DownloadManager dm = (DownloadManager) getSystemService(Context.DOWNLOAD_SERVICE);
            dm.enqueue(req);
            Toast.makeText(this, "开始下载：" + name, Toast.LENGTH_SHORT).show();
        } catch (Exception e) {
            Toast.makeText(this, "下载没成，换个办法再试", Toast.LENGTH_LONG).show();
        }
    }

    // ─────────────────────────── 杂项 ───────────────────────────

    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) {
            web.goBack();
            return;
        }
        super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        if (web != null) web.destroy();
        super.onDestroy();
    }

    int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }
}
