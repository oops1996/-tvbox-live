"""Apply the approved sidebar UI after the base customization and overlay copy."""

def apply(src, repo, replace):
    home = src / 'app/src/leanback/java/com/fongmi/android/tv/ui/activity/HomeActivity.java'
    replace(home, 'import com.fongmi.android.tv.ui.presenter.HistoryPresenter;',
                        'import com.fongmi.android.tv.ui.presenter.HistoryPresenter;\nimport com.fongmi.android.tv.ui.presenter.FamilyHistoryPresenter;\nimport com.fongmi.android.tv.ui.presenter.FamilyHeaderPresenter;\nimport com.fongmi.android.tv.ui.presenter.FamilyVodPresenter;\nimport com.fongmi.android.tv.family.FamilyStartup;\nimport android.widget.TextView;')
    replace(home, 'mClock = Clock.create(mBinding.clock);', 'mClock = Clock.create(mBinding.clock).format("HH:mm");')
    replace(home, '                mBinding.toolbar.setVisibility(position == 0 ? View.VISIBLE : View.GONE);', '                // Keep navigation and source controls visible while browsing.')
    replace(home, '        VodConfig.get().init().load(getCallback());', '        setRefreshing(true);\n        VodConfig.get().init().load(getCallback());')
    replace(home, '        WallConfig.get().init();', '        // The black theme does not load a wallpaper.')
    replace(home, '        mAdapter.add(new ListRow(mFuncAdapter = new ArrayObjectAdapter(new FuncPresenter(this))));', '')
    replace(home, 'new HeaderPresenter()', 'new FamilyHeaderPresenter()')
    replace(home, 'setVerticalSpacing(ResUtil.dp2px(16))', 'setVerticalSpacing(ResUtil.dp2px(6))')
    replace(home, 'R.string.home_history', 'R.string.family_continue', 2)
    replace(home, 'R.string.home_recommend', 'R.string.family_recommend', 2)
    replace(home, 'new CustomRowPresenter(16)', 'new CustomRowPresenter(16, FocusHighlight.ZOOM_FACTOR_NONE)', 2)
    replace(home, 'FocusHighlight.ZOOM_FACTOR_SMALL', 'FocusHighlight.ZOOM_FACTOR_NONE')
    replace(home, 'new HistoryPresenter(this)', 'new FamilyHistoryPresenter(this)', 2)
    replace(home, 'new VodPresenter(this, style)', 'new FamilyVodPresenter(this)')
    replace(home, 'Product.getColumn(style)', 'FamilyVodPresenter.columns()')
    replace(home, '        if (style.isList()) mAdapter.addAll(mAdapter.size(), result.getList());\n        else addGrid(result.getList(), style);', '        addGrid(result.getList(), style);\n        setCategories(result);\n        mBinding.empty.setVisibility(result.getList().isEmpty() ? View.VISIBLE : View.GONE);\n        mBinding.empty.setText("暂无推荐内容，可连接自己的影视接口或打开我的媒体。");')
    replace(home, '        mFuncAdapter.setItems(items, new BaseDiffCallback<Func>());', '        // Functions live in the fixed sidebar; retain all original destinations.')
    replace(home, '        if (!mBinding.title.hasFocus()) mBinding.recycler.requestFocus();', '        // Async configuration must not steal the user\'s current focus.')
    replace(home, '        mBinding.title.setFocusable(true);', '        mBinding.title.setFocusable(false);')
    replace(home, '            public void success(String result) {', '            public void success(String result) {\n                if (isFinishing() || isDestroyed()) return;')
    replace(home, '                showContent();\n                getHistory();', '                if (isFinishing() || isDestroyed()) return;\n                showContent();\n                getHistory();')
    replace(home, '                getHistory();\n                getVideo();\n                setLogo();', '                setRefreshing(false);\n                getHistory();\n                getVideo();\n                setLogo();', 1)
    replace(home, '                Notify.show(msg);\n                showContent();', '''                if (isFinishing() || isDestroyed()) return;
                setRefreshing(false);
                mBinding.empty.setText("接口加载失败，请刷新或切换源连接。");
                mBinding.empty.setVisibility(View.VISIBLE);
                Notify.show("接口加载失败，请检查网络或切换源连接");
                showContent();''')
    replace(home, '        mBinding.title.setListener(this);', '''        mBinding.title.setListener(this);
        mBinding.sourceConnect.setOnClickListener(v -> startActivity(new Intent(this, FamilySourcesActivity.class)));
        mBinding.sourceRefresh.setOnClickListener(v -> refreshSource());
        mBinding.sourceSite.setOnClickListener(v -> showDialog());
        mBinding.navFilms.setOnClickListener(v -> focusFilms());
        mBinding.navMedia.setOnClickListener(v -> startActivity(new Intent(this, FamilyMediaActivity.class)));
        mBinding.navLive.setOnClickListener(v -> LiveActivity.start(this));
        mBinding.navSearch.setOnClickListener(v -> SearchActivity.start(this));
        mBinding.navKeep.setOnClickListener(v -> KeepActivity.start(this));
        mBinding.navHistory.setOnClickListener(v -> focusHistory());
        mBinding.navMore.setOnClickListener(v -> new MaterialAlertDialogBuilder(this).setTitle("更多")
                .setItems(new String[]{"推送", "投屏", "电视系统设置", "电视应用列表"}, (d, index) -> {
                    if (index == 0) PushActivity.start(this);
                    else if (index == 1) CastActivity.start(this);
                    else if (index == 2) FamilyStartup.openSystemSettings(this);
                    else FamilyStartup.openApps(this);
                }).setNegativeButton("取消", null).show());
        mBinding.navSettings.setOnClickListener(v -> SettingActivity.start(this));
        mBinding.navFilms.setActivated(true);
        for (View nav : new View[]{mBinding.navFilms, mBinding.navMedia, mBinding.navLive, mBinding.navSearch,
                mBinding.navKeep, mBinding.navHistory, mBinding.navMore, mBinding.navSettings}) {
            if (nav instanceof TextView) {
                TextView label = (TextView) nav;
                android.graphics.drawable.Drawable icon = label.getCompoundDrawablesRelative()[0];
                if (icon != null) { icon.setBounds(0, 0, ResUtil.dp2px(22), ResUtil.dp2px(22)); label.setCompoundDrawablesRelative(icon, null, null, null); }
            }
            nav.setOnKeyListener((v, key, event) -> {
                if (event.getAction() == KeyEvent.ACTION_DOWN && key == KeyEvent.KEYCODE_DPAD_RIGHT) {
                    mBinding.sourceConnect.requestFocus(); return true;
                }
                return false;
            });
        }
        for (View action : new View[]{mBinding.sourceConnect, mBinding.sourceRefresh, mBinding.sourceSite}) {
            action.setOnKeyListener((v, key, event) -> {
                if (event.getAction() == KeyEvent.ACTION_DOWN && key == KeyEvent.KEYCODE_DPAD_DOWN
                        && mBinding.categories.getChildCount() > 0) {
                    mBinding.categories.getChildAt(0).requestFocus(); return true;
                }
                return false;
            });
        }
        setCategories(Result.empty());''')
    replace(home, '        optional.ifPresent(s -> mBinding.title.setText(s));', '        optional.ifPresent(s -> mBinding.title.setText(s));\n        mBinding.sourceSite.setText("切换站点");')
    start = home.read_text().index('    private void resetHome() {')
    end = home.read_text().index('    private void confirmExit()', start)
    text = home.read_text()
    text = text[:start] + '''    private void resetHome() {
        if (exitDialog != null) exitDialog.dismiss();
        mBinding.toolbar.setVisibility(View.VISIBLE);
        mBinding.recycler.setSelectedPosition(0);
        mBinding.navFilms.requestFocus();
    }

    private void focusFilms() {
        mBinding.recycler.setSelectedPosition(0);
        if (!mBinding.recycler.requestFocus()) mBinding.sourceConnect.requestFocus();
    }

    private void focusHistory() {
        if (mHistoryAdapter.size() == 0) { Notify.show("暂无观看历史"); return; }
        mBinding.recycler.setSelectedPosition(getHistoryIndex());
        mBinding.recycler.requestFocus();
    }

    private void refreshSource() {
        if (!mBinding.sourceRefresh.isEnabled()) return;
        setRefreshing(true);
        mResult = Result.empty();
        int index = getRecommendIndex();
        if (mAdapter.size() > index) mAdapter.removeItems(index, mAdapter.size() - index);
        mBinding.empty.setVisibility(View.GONE);
        VodConfig.load(getConfig(), getCallback());
    }

    private void setRefreshing(boolean refreshing) {
        if (isFinishing() || isDestroyed()) return;
        mBinding.sourceRefresh.setEnabled(!refreshing);
        mBinding.sourceRefresh.setText(refreshing ? "刷新中…" : "刷新");
    }

    private void setCategories(Result result) {
        View focused = mBinding.categories.findFocus();
        Object selected = focused == null ? null : focused.getTag();
        mBinding.categories.removeAllViews();
        TextView all = category("全部", true);
        all.setTag("");
        all.setOnClickListener(v -> {
            if (mResult.getTypes().isEmpty()) Notify.show("请先连接可用的影视接口");
            else VodActivity.start(this, mResult);
        });
        for (com.fongmi.android.tv.bean.Class type : result.getTypes()) {
            TextView item = category(type.getTypeName(), false);
            item.setTag(type.getTypeId());
            item.setOnClickListener(v -> {
                Intent intent = new Intent(this, VodActivity.class);
                intent.putExtra("key", getHome().getKey());
                intent.putExtra("result", mResult);
                intent.putExtra("family_type", type.getTypeId());
                startActivity(intent);
            });
        }
        if (selected != null) {
            for (int i = 0; i < mBinding.categories.getChildCount(); i++) {
                View item = mBinding.categories.getChildAt(i);
                if (selected.equals(item.getTag())) { item.requestFocus(); break; }
            }
        }
    }

    private TextView category(String label, boolean active) {
        TextView item = new TextView(this);
        item.setText(label); item.setTextSize(15); item.setGravity(android.view.Gravity.CENTER);
        item.setTextColor(getResources().getColorStateList(R.color.family_pill_text));
        item.setBackgroundResource(R.drawable.family_pill);
        item.setActivated(active); item.setFocusable(true); item.setFocusableInTouchMode(true);
        item.setPadding(ResUtil.dp2px(20), 0, ResUtil.dp2px(20), 0);
        android.widget.LinearLayout.LayoutParams params = new android.widget.LinearLayout.LayoutParams(-2, ResUtil.dp2px(34));
        params.setMarginEnd(ResUtil.dp2px(8)); mBinding.categories.addView(item, params);
        item.setNextFocusDownId(R.id.recycler); item.setNextFocusUpId(R.id.sourceConnect);
        item.setOnKeyListener((v, key, event) -> {
            if (event.getAction() != KeyEvent.ACTION_DOWN) return false;
            if (key == KeyEvent.KEYCODE_DPAD_LEFT && mBinding.categories.indexOfChild(item) == 0) {
                mBinding.navFilms.requestFocus(); return true;
            }
            if (key == KeyEvent.KEYCODE_DPAD_DOWN) {
                focusFilms(); return true;
            }
            return false;
        });
        return item;
    }

    @Override protected boolean customWall() { return false; }

''' + text[end:]
    home.write_text(text)
    replace(home, '                    finishAndRemoveTask();', '                    if (FamilyStartup.isDefaultHome(this)) FamilyStartup.openOriginalHome(this);\n                    finishAndRemoveTask();')
    replace(home, '        if (KeyUtil.isActionDown(event) & KeyUtil.isDownKey(event) && getCurrentFocus() == mBinding.title) return mBinding.recycler.getChildAt(0).requestFocus();', '''        if (event.getAction() == KeyEvent.ACTION_DOWN && event.getKeyCode() == KeyEvent.KEYCODE_DPAD_LEFT) {
            RecyclerView.ViewHolder holder = mBinding.recycler.findViewHolderForAdapterPosition(mBinding.recycler.getSelectedPosition());
            if (holder instanceof ItemBridgeAdapter.ViewHolder) {
                androidx.leanback.widget.Presenter.ViewHolder row = ((ItemBridgeAdapter.ViewHolder) holder).getViewHolder();
                if (row instanceof ListRowPresenter.ViewHolder) {
                    HorizontalGridView grid = ((ListRowPresenter.ViewHolder) row).getGridView();
                    if (grid.hasFocus() && grid.getSelectedPosition() == 0) { mBinding.navFilms.requestFocus(); return true; }
                }
            }
        }''')
    replace(home, '        mClock.start();', '        setTitle();\n        mClock.start();')
    replace(home, '        boolean gone = mAdapter.indexOf("progress") == -1;', '        mBinding.empty.setVisibility(View.GONE);\n        boolean gone = mAdapter.indexOf("progress") == -1;')
    boot = src / 'app/src/leanback/java/com/fongmi/android/tv/receiver/BootReceiver.java'
    replace(boot, '        com.fongmi.android.tv.Setting.putBootLive(false);', '''        if (!com.fongmi.android.tv.family.FamilyStartup.isEnabled(context)) return;
        com.fongmi.android.tv.family.FamilyStartup.recordBoot(context);
        com.fongmi.android.tv.Setting.putBootLive(false);''')
    settings = src / 'app/src/leanback/java/com/fongmi/android/tv/ui/activity/SettingActivity.java'
    replace(settings, '        mBinding.familySources.setOnClickListener', '        mBinding.familyStartup.setOnClickListener(v -> startActivity(new Intent(this, FamilyStartupActivity.class)));\n        mBinding.familySources.setOnClickListener')
    layout = src / 'app/src/leanback/res/layout/activity_setting.xml'
    replace(layout, '        android:padding="24dp">', '''        android:padding="24dp">
        <com.google.android.material.button.MaterialButton
            android:id="@+id/familyStartup" android:layout_width="match_parent" android:layout_height="wrap_content"
            android:focusable="true" android:text="开机自动启动 · 权限与桌面设置" />''')
    vod = src / 'app/src/leanback/java/com/fongmi/android/tv/ui/activity/VodActivity.java'
    replace(vod, '        setPager();', '''        setPager();
        String initial = getIntent().getStringExtra("family_type");
        if (initial != null) {
            for (int i = 0; i < getResult().getTypes().size(); i++) {
                if (initial.equals(getResult().getTypes().get(i).getTypeId())) {
                    mBinding.recycler.setSelectedPosition(i);
                    mBinding.pager.setCurrentItem(i, false); break;
                }
            }
        }''')
    base = src / 'app/src/leanback/java/com/fongmi/android/tv/ui/base/BaseActivity.java'
    replace(base, '        return true;', '        return false;', 1)
    styles = src / 'app/src/leanback/res/values/styles.xml'
    replace(styles, 'Theme.MaterialComponents.Light.NoActionBar', 'Theme.MaterialComponents.NoActionBar')
    replace(styles, 'Theme.MaterialComponents.Light.BottomSheetDialog', 'Theme.MaterialComponents.BottomSheetDialog')
    replace(styles, '#06142F', '#080A0D')
    colors = src / 'app/src/leanback/res/values/colors.xml'
    replace(colors, '<color name="accent">@color/blue_500</color>', '<color name="accent">#DEE2EA</color>')
    main = src / 'app/src/main/AndroidManifest.xml'
    replace(main, '    <queries>', '''    <queries>
        <intent><action android:name="android.intent.action.MAIN" /><category android:name="android.intent.category.HOME" /></intent>''')
    tv = src / 'app/src/leanback/AndroidManifest.xml'
    replace(tv, 'android:clearTaskOnLaunch="true"\n            android:launchMode="singleTop"', 'android:clearTaskOnLaunch="true"\n            android:launchMode="singleTask"')
    replace(tv, '    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />', '''    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />''')
    replace(tv, '        <activity android:name=".ui.activity.FamilyMediaActivity"', '''        <activity android:name=".ui.activity.FamilyStartupActivity" android:exported="false" android:screenOrientation="sensorLandscape" />
        <activity-alias android:name=".FamilyTvLauncher" android:targetActivity=".ui.activity.HomeActivity"
            android:enabled="false" android:exported="true" android:label="@string/app_name">
            <intent-filter><action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.HOME" />
                <category android:name="android.intent.category.DEFAULT" /></intent-filter>
        </activity-alias>
        <activity android:name=".ui.activity.FamilyMediaActivity"''')

