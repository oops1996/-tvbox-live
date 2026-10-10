package com.fongmi.android.tv.ui.activity;

import android.view.View;
import androidx.viewbinding.ViewBinding;
import com.fongmi.android.tv.databinding.ActivityFamilyStartupBinding;
import com.fongmi.android.tv.family.FamilyStartup;
import com.fongmi.android.tv.ui.base.BaseActivity;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import java.text.DateFormat;
import java.util.Date;

public class FamilyStartupActivity extends BaseActivity {
    private ActivityFamilyStartupBinding binding;
    @Override protected ViewBinding getBinding() { return binding = ActivityFamilyStartupBinding.inflate(getLayoutInflater()); }
    @Override protected void initView() { render(); binding.startupToggle.requestFocus(); }
    @Override protected void initEvent() {
        binding.startupToggle.setOnClickListener(v -> { FamilyStartup.setEnabled(this, !FamilyStartup.isEnabled(this)); render(); });
        binding.overlay.setOnClickListener(v -> FamilyStartup.openOverlaySettings(this));
        binding.appSettings.setOnClickListener(v -> FamilyStartup.openAppSettings(this));
        binding.systemSettings.setOnClickListener(v -> FamilyStartup.openSystemSettings(this));
        binding.homeEnable.setOnClickListener(v -> new MaterialAlertDialogBuilder(this).setTitle("设为电视默认桌面？")
                .setMessage("开启后需在电视系统页面选择家庭电视。Home 键和系统启动桌面可能进入本应用；你可以在这里恢复原电视桌面。仅部分电视支持。")
                .setNegativeButton("取消", null).setPositiveButton("打开桌面选择", (d, which) -> { FamilyStartup.enableHome(this); render(); }).show());
        binding.homeDisable.setOnClickListener(v -> { FamilyStartup.disableHome(this); render(); });
    }
    @Override protected void onResume() { super.onResume(); render(); }
    private void render() {
        if (binding == null) return;
        boolean enabled = FamilyStartup.isEnabled(this);
        binding.startupToggle.setText("开机自动启动：" + (enabled ? "已开启" : "已关闭"));
        binding.status.setText("后台启动相关权限：" + (FamilyStartup.hasOverlayPermission(this) ? "已允许显示在其他应用上层" : "尚未允许显示在其他应用上层")
                + "\n默认桌面：" + (FamilyStartup.isDefaultHome(this) ? "家庭电视" : "系统原桌面或尚未选择"));
        binding.homeDisable.setVisibility(FamilyStartup.isHomeEnabled(this) ? View.VISIBLE : View.GONE);
        long request = FamilyStartup.lastBootRequest(this);
        binding.lastBoot.setText(request == 0 ? "尚未记录到开机启动请求，开启后请重启电视验证。"
                : "上次开机启动请求：" + DateFormat.getDateTimeInstance().format(new Date(request)) + "\n该记录不代表系统已成功显示应用，请以电视实际启动结果为准。");
    }
}
