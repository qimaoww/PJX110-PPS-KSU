#!/system/bin/sh
MODDIR="/data/adb/modules/ace3pro_pps33"
echo "module_dir=$MODDIR"
echo "module_present=$([ -f "$MODDIR/module.prop" ] && echo 1 || echo 0)"
echo "slot=$(sh "$MODDIR/bin/dtbo_state.sh" 2>/dev/null | sed -n "s/^slot_suffix=//p" | head -n1)"
echo "uid=$(id -u 2>/dev/null)"
echo "context=$(id -Z 2>/dev/null)"
echo "--- dtbo_state ---"
sh "$MODDIR/bin/dtbo_state.sh" 2>&1
echo "--- telemetry ---"
sh "$MODDIR/bin/status.sh" 2>&1 | head -n 30

echo "root_action_present=$([ -f "$MODDIR/action.sh" ] && echo 1 || echo 0)"
echo "webui_toggle_present=$([ -f "$MODDIR/bin/toggle.sh" ] && echo 1 || echo 0)"

echo "--- boot_state ---"
sh "$MODDIR/bin/boot_state.sh" 2>&1
