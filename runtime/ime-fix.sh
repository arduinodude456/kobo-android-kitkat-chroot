#!/system/bin/sh
# KitKat can retain an old/empty IME selection in /data. Re-enable LatinIME
# after framework boot and select it explicitly.
IME='com.android.inputmethod.latin/.LatinIME'
i=0
while [ "$(getprop sys.boot_completed)" != '1' ] && [ "$i" -lt 90 ]; do
    sleep 1
    i=$((i + 1))
done
settings put secure enabled_input_methods "$IME"
settings put secure default_input_method "$IME"
# ime is present on the KitKat framework; tolerate builds without the helper.
ime enable "$IME" >/dev/null 2>&1 || true
ime set "$IME" >/dev/null 2>&1 || true
