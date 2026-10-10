package com.fongmi.android.tv.ui.presenter;

import android.view.LayoutInflater;
import android.view.ViewGroup;
import androidx.annotation.NonNull;
import androidx.leanback.widget.Presenter;
import com.fongmi.android.tv.Product;
import com.fongmi.android.tv.R;
import com.fongmi.android.tv.databinding.AdapterVodRectBinding;
import com.fongmi.android.tv.ui.holder.VodRectHolder;
import com.fongmi.android.tv.utils.ResUtil;

/** Size posters to the content pane rather than the entire television. */
public class FamilyVodPresenter extends VodPresenter {
    private final OnClickListener listener;
    public FamilyVodPresenter(OnClickListener listener) { super(listener); this.listener = listener; }
    public static int columns() { return Math.max(3, Math.min(6, Product.getColumn())); }

    @NonNull @Override public Presenter.ViewHolder onCreateViewHolder(@NonNull ViewGroup parent) {
        int width = (ResUtil.getScreenWidth() - ResUtil.dp2px(216 + 16 * (columns() - 1))) / columns();
        AdapterVodRectBinding binding = AdapterVodRectBinding.inflate(LayoutInflater.from(parent.getContext()), parent, false);
        binding.getRoot().setForeground(parent.getContext().getDrawable(R.drawable.family_card_focus));
        binding.name.setGravity(android.view.Gravity.START);
        binding.name.setBackgroundColor(0xff080a0d);
        binding.name.setTextSize(14);
        binding.name.setPadding(ResUtil.dp2px(2), ResUtil.dp2px(4), ResUtil.dp2px(2), ResUtil.dp2px(4));
        return new VodRectHolder(binding, listener).size(new int[]{width, (int) (width / 0.75f)});
    }
}
