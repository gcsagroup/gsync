package org.gcsa.pbsync.android;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

final class LibraryUi {
    static final int CANVAS = 0xfff5f8f7;
    static final int SURFACE = 0xffffffff;
    static final int INK = 0xff172826;
    static final int MUTED = 0xff4b625e;
    static final int ACCENT = 0xff006b59;
    static final int TINT = 0xffe0f1ec;
    static final int BORDER = 0xffdbe6e2;
    static final int QUIET = 0xff6d837d;

    enum Icon {
        BOOKMARK(0xe867), VAULT(0xe899), SYNC(0xe627), SEARCH(0xe8b6), CLOSE(0xe5cd),
        FOLDER(0xe2c7), WEBSITE(0xe894), ACCOUNT(0xe853), MORE(0xe5d4),
        LEFT(0xe5cb), SHIELD(0xe8e8), FILE(0xe873), LOCK(0xe897);
        final int code;
        Icon(int code) { this.code = code; }
    }

    private final Context context;
    private final Typeface icons;

    LibraryUi(Context context) {
        this.context = context;
        icons = Typeface.createFromAsset(context.getAssets(), "fonts/MaterialIcons-Regular.ttf");
    }

    int dp(float value) { return Math.round(value * context.getResources().getDisplayMetrics().density); }

    LinearLayout column() {
        LinearLayout view = new LinearLayout(context);
        view.setOrientation(LinearLayout.VERTICAL);
        return view;
    }

    LinearLayout row() {
        LinearLayout view = new LinearLayout(context);
        view.setGravity(Gravity.CENTER_VERTICAL);
        return view;
    }

    TextView text(String label, int size, int color, boolean emphasized) {
        TextView view = new TextView(context);
        view.setText(label);
        view.setTextSize(size);
        view.setTextColor(color);
        view.setTypeface(Typeface.create(emphasized ? "sans-serif-medium" : "sans-serif", Typeface.NORMAL));
        return view;
    }

    TextView icon(Icon icon, int size, int color) {
        TextView view = text(new String(Character.toChars(icon.code)), size, color, false);
        view.setTypeface(icons);
        view.setGravity(Gravity.CENTER);
        view.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        return view;
    }

    TextView badge(Icon icon, int size, int color, int fill) {
        TextView view = icon(icon, size, color);
        view.setBackground(shape(fill, 13, 0));
        return view;
    }

    GradientDrawable shape(int fill, int corner, int line) {
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(fill);
        shape.setCornerRadius(dp(corner));
        if (line != 0) shape.setStroke(dp(1), line);
        return shape;
    }

    RippleDrawable ripple(int fill, int corner, int line) {
        return new RippleDrawable(ColorStateList.valueOf(0x18006b59),
            shape(fill, corner, line), shape(SURFACE, corner, 0));
    }

    View divider() {
        View line = new View(context);
        line.setBackgroundColor(BORDER);
        line.setLayoutParams(new LinearLayout.LayoutParams(-1, dp(1)));
        return line;
    }

    Button button(String label, boolean primary, Runnable click) {
        Button view = new Button(context);
        view.setAllCaps(false);
        view.setText(label);
        view.setTextSize(14);
        view.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        view.setTextColor(primary ? SURFACE : ACCENT);
        view.setMinHeight(dp(46));
        view.setMinimumHeight(dp(46));
        view.setMinWidth(dp(48));
        view.setMinimumWidth(dp(48));
        view.setPadding(dp(13), dp(7), dp(13), dp(7));
        view.setStateListAnimator(null);
        view.setBackground(ripple(primary ? ACCENT : SURFACE, 15, primary ? 0 : BORDER));
        view.setOnClickListener(v -> click.run());
        return view;
    }

    TextView iconButton(Icon icon, String title, Runnable click) {
        TextView view = icon(icon, 22, ACCENT);
        view.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
        view.setContentDescription(title);
        view.setFocusable(true);
        view.setBackground(ripple(0x00000000, 16, 0));
        view.setOnClickListener(v -> click.run());
        return view;
    }

    LinearLayout nav(Icon icon, String label, boolean selected, Runnable click) {
        LinearLayout view = column();
        view.setGravity(Gravity.CENTER);
        view.setPadding(0, dp(7), 0, dp(7));
        TextView plate = icon(icon, 23, selected ? ACCENT : MUTED);
        plate.setBackground(shape(selected ? TINT : SURFACE, 16, 0));
        view.addView(plate, new LinearLayout.LayoutParams(dp(57), dp(31)));
        TextView title = text(label, 12, selected ? ACCENT : MUTED, selected);
        title.setPadding(0, dp(3), 0, 0);
        title.setGravity(Gravity.CENTER);
        view.addView(title, new LinearLayout.LayoutParams(-1, -2));
        view.setSelected(selected);
        view.setContentDescription(label);
        view.setFocusable(true);
        view.setBackground(ripple(SURFACE, 14, 0));
        view.setOnClickListener(v -> click.run());
        return view;
    }
}
