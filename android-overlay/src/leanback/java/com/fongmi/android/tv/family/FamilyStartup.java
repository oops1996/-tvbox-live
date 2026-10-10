package com.fongmi.android.tv.family;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import com.fongmi.android.tv.utils.Notify;

/** Opt-in system settings, with no device admin, root or persistent relaunch loop. */
public final class FamilyStartup {
    private FamilyStartup() {}
    private static SharedPreferences prefs(Context context) { return context.getSharedPreferences("family_startup_private", 0); }
    private static ComponentName launcher(Context context) { return new ComponentName(context, "com.fongmi.android.tv.FamilyTvLauncher"); }
    private static Intent homeIntent() { return new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME); }
    public static boolean isEnabled(Context context) { return prefs(context).getBoolean("enabled", true); }
    public static void setEnabled(Context context, boolean enabled) {
        prefs(context).edit().putBoolean("enabled", enabled).apply();
        if (!enabled) disableHome(context);
    }
    public static void recordBoot(Context context) { prefs(context).edit().putLong("last_boot_request", System.currentTimeMillis()).apply(); }
    public static long lastBootRequest(Context context) { return prefs(context).getLong("last_boot_request", 0); }
    public static boolean hasOverlayPermission(Context context) { return Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(context); }
    public static boolean isDefaultHome(Context context) {
        ResolveInfo info = context.getPackageManager().resolveActivity(homeIntent(), PackageManager.MATCH_DEFAULT_ONLY);
        return info != null && info.activityInfo != null && context.getPackageName().equals(info.activityInfo.packageName);
    }
    public static boolean isHomeEnabled(Context context) {
        return context.getPackageManager().getComponentEnabledSetting(launcher(context)) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED;
    }
    public static void enableHome(Activity activity) {
        ResolveInfo previous = activity.getPackageManager().resolveActivity(homeIntent(), PackageManager.MATCH_DEFAULT_ONLY);
        if (previous != null && previous.activityInfo != null && !activity.getPackageName().equals(previous.activityInfo.packageName)) {
            prefs(activity).edit().putString("original_home", new ComponentName(previous.activityInfo.packageName, previous.activityInfo.name).flattenToString()).apply();
        }
        setEnabled(activity, true);
        activity.getPackageManager().setComponentEnabledSetting(launcher(activity), PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP);
        if (!open(activity, new Intent(Settings.ACTION_HOME_SETTINGS))) {
            // Roll back the optional alias if this firmware provides no selection UI.
            disableHome(activity);
            Notify.show("电视未提供默认桌面选择页，请使用开机自启和系统权限设置");
        }
    }
    public static void disableHome(Context context) {
        context.getPackageManager().setComponentEnabledSetting(launcher(context), PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP);
    }
    public static void openOriginalHome(Activity activity) {
        ComponentName previous = ComponentName.unflattenFromString(prefs(activity).getString("original_home", ""));
        if (previous != null && !activity.getPackageName().equals(previous.getPackageName())) {
            Intent intent = homeIntent().setComponent(previous).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
            if (open(activity, intent)) return;
        }
        disableHome(activity);
        if (!open(activity, homeIntent().addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))) openSystemSettings(activity);
    }
    public static void openOverlaySettings(Activity activity) {
        if (Build.VERSION.SDK_INT < 23) { Notify.show("此系统无需单独开启后台启动相关权限"); return; }
        if (!open(activity, new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + activity.getPackageName())))) {
            Notify.show("电视未提供此权限页，请在系统应用设置中检查自启动权限"); openAppSettings(activity);
        }
    }
    public static void openAppSettings(Activity activity) {
        if (!open(activity, new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + activity.getPackageName())))) openSystemSettings(activity);
    }
    public static void openSystemSettings(Activity activity) {
        if (!open(activity, new Intent(Settings.ACTION_SETTINGS))) Notify.show("电视未提供可打开的系统设置页");
    }
    public static void openApps(Activity activity) {
        if (!open(activity, new Intent(Intent.ACTION_ALL_APPS)) && !open(activity, new Intent(Settings.ACTION_MANAGE_APPLICATIONS_SETTINGS))) openSystemSettings(activity);
    }
    private static boolean open(Activity activity, Intent intent) {
        try { activity.startActivity(intent); return true; }
        catch (RuntimeException unavailable) { return false; }
    }
}
