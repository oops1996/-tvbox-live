package com.fongmi.android.tv.ui.presenter;

import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.ProgressBar;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.leanback.widget.Presenter;
import com.bumptech.glide.Glide;
import com.fongmi.android.tv.R;
import com.fongmi.android.tv.bean.History;
import com.fongmi.android.tv.utils.ImgUtil;
import com.fongmi.android.tv.utils.ResUtil;

/** Real resume progress; unknown durations never become fabricated percentages. */
public class FamilyHistoryPresenter extends HistoryPresenter {
    private final OnClickListener listener;
    public FamilyHistoryPresenter(OnClickListener listener) { super(listener); this.listener = listener; }

    @NonNull @Override public Presenter.ViewHolder onCreateViewHolder(@NonNull ViewGroup parent) {
        View view = LayoutInflater.from(parent.getContext()).inflate(R.layout.family_history_card, parent, false);
        int width = (ResUtil.getScreenWidth() - ResUtil.dp2px(248)) / 3;
        view.getLayoutParams().width = width;
        view.findViewById(R.id.image).getLayoutParams().height = (width - ResUtil.dp2px(8)) / 2;
        return new Holder(view);
    }

    @Override public void onBindViewHolder(Presenter.ViewHolder viewHolder, Object object) {
        History item = (History) object;
        Holder holder = (Holder) viewHolder;
        holder.name.setText(item.getVodName());
        boolean known = item.getDuration() > 0 && item.getPosition() >= 0;
        int percent = known ? (int) Math.min(100, Math.max(0, 100.0 * item.getPosition() / item.getDuration())) : 0;
        holder.progress.setProgress(percent);
        holder.progress.setVisibility(known && !isDelete() ? View.VISIBLE : View.INVISIBLE);
        holder.position.setText(isDelete() ? "删除" : known ? "已观看 " + percent + "%" : item.getVodRemarks());
        ImgUtil.load(item.getVodName(), item.getVodPic(), holder.image);
        holder.view.setOnClickListener(v -> { if (isDelete()) listener.onItemDelete(item); else listener.onItemClick(item); });
        holder.view.setOnLongClickListener(v -> listener.onLongClick());
    }

    @Override public void onUnbindViewHolder(Presenter.ViewHolder viewHolder) {
        Holder holder = (Holder) viewHolder;
        Glide.with(holder.image).clear(holder.image);
        holder.view.setOnClickListener(null); holder.view.setOnLongClickListener(null);
    }

    private static class Holder extends Presenter.ViewHolder {
        final ImageView image;
        final TextView name, position;
        final ProgressBar progress;
        Holder(View view) {
            super(view); image = view.findViewById(R.id.image); name = view.findViewById(R.id.name);
            position = view.findViewById(R.id.position); progress = view.findViewById(R.id.progress);
        }
    }
}
