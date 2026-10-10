package com.fongmi.android.tv.ui.presenter;

import android.graphics.Typeface;
import android.view.ViewGroup;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.leanback.widget.Presenter;
import com.fongmi.android.tv.R;

public class FamilyHeaderPresenter extends HeaderPresenter {
    @NonNull @Override public Presenter.ViewHolder onCreateViewHolder(@NonNull ViewGroup parent) {
        Presenter.ViewHolder holder = super.onCreateViewHolder(parent);
        TextView title = holder.view.findViewById(R.id.text);
        title.setTextSize(20); title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        title.setIncludeFontPadding(false);
        return holder;
    }
}
