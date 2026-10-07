package com.fongmi.android.tv.ui.activity;

import android.content.SharedPreferences;
import android.os.Bundle;
import android.text.InputType;
import android.text.TextUtils;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.app.AppCompatActivity;

import com.fongmi.android.tv.R;
import com.fongmi.android.tv.api.config.VodConfig;
import com.fongmi.android.tv.bean.Config;
import com.fongmi.android.tv.event.RefreshEvent;
import com.fongmi.android.tv.impl.Callback;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;

import java.text.DateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;

import okhttp3.HttpUrl;

/** Reuse the upstream config database; availability/status metadata stays local. */
public class FamilySourcesActivity extends AppCompatActivity {
    public static final String DEFAULT_URL = "https://cdn.jsdelivr.net/gh/oops1996/-tvbox-live@main/config.json";
    private List<Config> sources = new ArrayList<>();
    private ListView list;
    private TextView status;
    private SharedPreferences prefs;
    private boolean loading;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        prefs = getSharedPreferences("family_sources_private", 0);
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(32, 24, 32, 24); root.setBackgroundColor(0xff06142f);
        TextView title = new TextView(this); title.setText("接口管理 · 本机保存"); title.setTextSize(24); title.setTextColor(0xffffffff); root.addView(title);
        Button add = new Button(this); add.setText("添加合法、有权使用的接口 URL"); add.setOnClickListener(v -> edit(null)); root.addView(add);
        Button fallback = new Button(this); fallback.setText("切换到默认影视接口"); fallback.setOnClickListener(v -> use(defaultConfig())); root.addView(fallback);
        status = new TextView(this); status.setTextColor(0xffffffff); root.addView(status);
        list = new ListView(this); list.setSelector(R.drawable.selector_item); root.addView(list, new LinearLayout.LayoutParams(-1, 0, 1));
        list.setOnItemClickListener((parent, view, index, id) -> actions(sources.get(index)));
        setContentView(root); render();
    }

    private Config defaultConfig() { return Config.find(DEFAULT_URL, "家庭电视", 0).save(); }

    private boolean disabled(Config item) { return prefs.getBoolean("disabled_" + item.getUrl(), false); }

    public static boolean isDisabled(Config item) {
        return com.fongmi.android.tv.App.get().getSharedPreferences("family_sources_private", 0)
                .getBoolean("disabled_" + item.getUrl(), false);
    }

    private void render() {
        if (isFinishing() || isDestroyed()) return;
        sources = Config.getAll(0);
        List<String> labels = new ArrayList<>();
        for (Config item : sources) {
            String label = item.getDesc() + (item.equals(VodConfig.get().getConfig()) ? " · 当前" : "") + (disabled(item) ? " · 已停用" : "");
            String state = prefs.getString("state_" + item.getUrl(), "尚未检查");
            long last = prefs.getLong("checked_" + item.getUrl(), 0);
            labels.add(label + "\n" + state + (last == 0 ? "" : " · " + DateFormat.getDateTimeInstance().format(new Date(last))));
        }
        list.setAdapter(new ArrayAdapter<String>(this, android.R.layout.simple_list_item_1, labels) {
            @Override public View getView(int position, View recycled, ViewGroup parent) {
                TextView row = (TextView) super.getView(position, recycled, parent);
                row.setTextColor(0xffffffff); row.setTextSize(20); row.setPadding(16, 16, 16, 16); return row;
            }
        }); list.requestFocus();
    }

    private void actions(Config item) {
        if (loading) return;
        new MaterialAlertDialogBuilder(this).setTitle(item.getDesc())
                .setItems(new String[]{"切换 / 手动刷新", "修改名称和 URL", disabled(item) ? "启用" : "停用", "删除"}, (d, which) -> {
                    if (which == 0) use(item);
                    else if (which == 1) edit(item);
                    else if (which == 2) toggle(item);
                    else remove(item);
                }).setNegativeButton("取消", null).show();
    }

    private void toggle(Config item) {
        if (DEFAULT_URL.equals(item.getUrl())) { status.setText("默认接口作为兜底，始终可用"); return; }
        boolean disable = !disabled(item);
        prefs.edit().putBoolean("disabled_" + item.getUrl(), disable).apply();
        if (disable && item.equals(VodConfig.get().getConfig())) use(defaultConfig()); else render();
    }

    private EditText field(LinearLayout form, String hint, String value) {
        EditText edit = new EditText(this); edit.setSingleLine(true); edit.setHint(hint); edit.setText(value);
        edit.setInputType(InputType.TYPE_CLASS_TEXT); form.addView(edit); return edit;
    }

    private void edit(Config item) {
        LinearLayout form = new LinearLayout(this); form.setOrientation(LinearLayout.VERTICAL); form.setPadding(24, 12, 24, 12);
        EditText name = field(form, "接口名称", item == null ? "" : item.getName());
        EditText url = field(form, "HTTP/HTTPS 接口 URL", item == null ? "" : item.getUrl());
        AlertDialog dialog = new MaterialAlertDialogBuilder(this).setTitle(item == null ? "添加接口" : "修改接口")
                .setView(form).setPositiveButton("保存", null).setNegativeButton("取消", null).create();
        dialog.setOnShowListener(d -> dialog.getButton(-1).setOnClickListener(v -> {
            String address = url.getText().toString().trim(), label = name.getText().toString().trim();
            HttpUrl parsed = HttpUrl.parse(address);
            if (parsed == null || !parsed.username().isEmpty() || !parsed.password().isEmpty()) { url.setError("请输入有效的 HTTP(S) URL；账号请在网盘连接页填写"); return; }
            if (item != null && DEFAULT_URL.equals(item.getUrl())) { url.setError("默认兜底地址不能修改，请添加新接口"); return; }
            if (item == null) Config.find(address, TextUtils.isEmpty(label) ? "自定义接口" : label, 0).save();
            else {
                if (!address.equals(item.getUrl()) && sources.stream().anyMatch(source -> source.getUrl().equals(address))) {
                    url.setError("该地址已经保存，请直接切换"); return;
                }
                // Keep existing histories by updating the same config ID.
                Config previous = Config.objectFrom(item.toString());
                prefs.edit().putBoolean("disabled_" + address, disabled(item)).apply();
                item.setUrl(address); item.setName(TextUtils.isEmpty(label) ? "自定义接口" : label); item.save();
                if (item.equals(VodConfig.get().getConfig())) use(item, previous);
            }
            dialog.dismiss(); render();
        }));
        dialog.show();
    }

    private void remove(Config item) {
        if (DEFAULT_URL.equals(item.getUrl())) { status.setText("默认接口作为兜底，不能删除"); return; }
        new MaterialAlertDialogBuilder(this).setTitle("删除接口？")
                .setMessage("仅从本机删除该接口，并清除它关联的观看历史和收藏。")
                .setNegativeButton("取消", null).setPositiveButton("删除", (d, which) -> {
                    boolean current = item.equals(VodConfig.get().getConfig());
                    item.delete(); if (current) use(defaultConfig()); else render();
                }).show();
    }

    private void use(Config item) {
        use(item, Config.find(VodConfig.getCid()));
    }

    private void use(Config item, Config previous) {
        if (loading) return;
        if (disabled(item)) { status.setText("请先启用该接口"); return; }
        loading = true; status.setText("正在加载接口…");
        VodConfig.load(item, new Callback() {
            @Override public void success() {
                loading = false; mark(item, "加载成功"); refresh();
                if (!isDestroyed()) { status.setText("当前接口：" + item.getDesc()); render(); }
            }
            @Override public void error(String message) {
                mark(item, "加载失败");
                Config restore = previous == null || previous.isEmpty() || disabled(previous) ? defaultConfig() : previous;
                VodConfig.load(restore, new Callback() {
                    @Override public void success() { done(); }
                    @Override public void error(String msg) { done(); }
                    private void done() { loading = false; refresh(); if (!isDestroyed()) { status.setText("接口加载失败，已返回之前或默认接口"); render(); } }
                });
            }
        });
    }

    private void mark(Config item, String state) {
        prefs.edit().putString("state_" + item.getUrl(), state).putLong("checked_" + item.getUrl(), System.currentTimeMillis()).apply();
    }

    private void refresh() { RefreshEvent.config(); RefreshEvent.video(); RefreshEvent.history(); }
}
