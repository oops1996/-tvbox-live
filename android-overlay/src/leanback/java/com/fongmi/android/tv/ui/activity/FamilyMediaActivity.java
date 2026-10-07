package com.fongmi.android.tv.ui.activity;

import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.activity.OnBackPressedCallback;
import androidx.appcompat.app.AppCompatActivity;

import com.fongmi.android.tv.R;
import com.fongmi.android.tv.family.FamilyMedia;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Read-only browsing of the user's private OpenList or WebDAV library. */
public class FamilyMediaActivity extends AppCompatActivity {
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final List<String> parents = new ArrayList<>();
    private List<FamilyMedia.Entry> entries = new ArrayList<>();
    private ListView list;
    private TextView status;
    private String mode = "openlist", path = "/";
    private int generation;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(32, 24, 32, 24); root.setBackgroundColor(0xff06142f);
        TextView title = new TextView(this); title.setText("我的媒体 · 本机连接");
        title.setTextSize(24); title.setTextColor(0xffffffff); root.addView(title);
        LinearLayout bar = new LinearLayout(this); root.addView(bar);
        for (String type : new String[]{"openlist", "webdav"}) {
            Button choose = new Button(this); choose.setText(type.equals("openlist") ? "OpenList" : "WebDAV");
            choose.setOnClickListener(v -> select(type)); bar.addView(choose);
        }
        Button configure = new Button(this); configure.setText("设置当前连接"); configure.setOnClickListener(v -> configure()); bar.addView(configure);
        Button up = new Button(this); up.setText("上一级"); up.setOnClickListener(v -> goUp()); bar.addView(up);
        Button refresh = new Button(this); refresh.setText("刷新"); refresh.setOnClickListener(v -> load(path, false)); bar.addView(refresh);
        status = new TextView(this); status.setTextColor(0xffffffff); status.setTextSize(18); root.addView(status);
        list = new ListView(this); list.setSelector(R.drawable.selector_item); root.addView(list, new LinearLayout.LayoutParams(-1, 0, 1));
        list.setOnItemClickListener((parent, view, index, id) -> {
            FamilyMedia.Entry entry = entries.get(index);
            if (entry.folder) load(entry.path, true);
            else try { VideoActivity.start(this, "family_media", FamilyMedia.id(mode, entry), entry.name); }
            catch (Exception e) { Toast.makeText(this, "无法打开媒体", Toast.LENGTH_SHORT).show(); }
        });
        setContentView(root);
        getOnBackPressedDispatcher().addCallback(this, new OnBackPressedCallback(true) {
            @Override public void handleOnBackPressed() { if (parents.isEmpty()) finish(); else goUp(); }
        });
        select(mode);
    }

    private void select(String type) {
        generation++; mode = type; parents.clear(); entries.clear();
        list.setEnabled(true);
        render();
        if (FamilyMedia.get(mode, "url").isEmpty()) {
            status.setText("请先设置 " + (mode.equals("openlist") ? "OpenList" : "WebDAV") + " 连接");
            return;
        }
        path = FamilyMedia.root(mode); load(path, false);
    }

    private void load(String target, boolean enter) {
        if (FamilyMedia.get(mode, "url").isEmpty()) { configure(); return; }
        final int task = ++generation;
        final String selected = mode;
        list.setEnabled(false); status.setText("正在读取目录…");
        executor.execute(() -> {
            try {
                List<FamilyMedia.Entry> result = FamilyMedia.list(selected, target);
                runOnUiThread(() -> {
                    if (isFinishing() || isDestroyed() || task != generation) return;
                    if (enter) parents.add(path);
                    else if (!parents.isEmpty() && parents.get(parents.size() - 1).equals(target)) parents.remove(parents.size() - 1);
                    path = target; entries = result; list.setEnabled(true);
                    render();
                    status.setText((selected.equals("openlist") ? "OpenList" : "WebDAV") + " · " + path + (result.isEmpty() ? " · 暂无媒体" : ""));
                    list.requestFocus();
                });
            } catch (Exception e) {
                runOnUiThread(() -> {
                    if (isFinishing() || isDestroyed() || task != generation) return;
                    list.setEnabled(true); status.setText("目录加载失败，请检查地址、网络和访问权限");
                });
            }
        });
    }

    private void goUp() {
        if (parents.isEmpty()) return;
        String target = parents.get(parents.size() - 1); load(target, false);
    }

    private void render() {
        list.setAdapter(new ArrayAdapter<FamilyMedia.Entry>(this, android.R.layout.simple_list_item_1, entries) {
            @Override public View getView(int position, View recycled, ViewGroup parent) {
                TextView row = (TextView) super.getView(position, recycled, parent);
                row.setTextColor(0xffffffff); row.setTextSize(20); row.setPadding(16, 16, 16, 16); return row;
            }
        });
    }

    private EditText field(LinearLayout form, String hint, String value, boolean secret) {
        EditText input = new EditText(this); input.setHint(hint); input.setText(value); input.setSingleLine(true);
        input.setInputType(secret ? InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD : InputType.TYPE_CLASS_TEXT);
        form.addView(input); return input;
    }

    private void configure() {
        final String selected = mode;
        LinearLayout form = new LinearLayout(this); form.setOrientation(LinearLayout.VERTICAL); form.setPadding(24, 12, 24, 12);
        EditText url = field(form, selected.equals("openlist") ? "OpenList 服务地址（HTTP/HTTPS）" : "WebDAV 地址（包含 /dav/ 路径）", FamilyMedia.get(selected, "url"), false);
        EditText user = field(form, "账号（允许匿名时可留空）", FamilyMedia.get(selected, "user"), false);
        EditText password = field(form, "密码（仅保存在本机）", FamilyMedia.get(selected, "password"), true);
        EditText start = field(form, "OpenList 起始目录，默认 /", FamilyMedia.get(selected, "root"), false);
        if (selected.equals("webdav")) start.setVisibility(View.GONE);
        androidx.appcompat.app.AlertDialog dialog = new MaterialAlertDialogBuilder(this)
                .setTitle(selected.equals("openlist") ? "OpenList 连接" : "WebDAV 连接").setView(form)
                .setNegativeButton("取消", null).setPositiveButton("保存", null).create();
        dialog.setOnShowListener(d -> dialog.getButton(-1).setOnClickListener(v -> {
            try {
                FamilyMedia.save(selected, url.getText().toString(), user.getText().toString(), password.getText().toString(), start.getText().toString());
                dialog.dismiss(); select(selected);
            } catch (IllegalArgumentException e) { url.setError(e.getMessage()); }
        }));
        dialog.show();
    }

    @Override protected void onDestroy() { generation++; executor.shutdownNow(); super.onDestroy(); }
}
