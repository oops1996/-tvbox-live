#!/usr/bin/env bash
set -euo pipefail
CUSTOM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="https://github.com/OttoHX/kknifer7_TV-K.git"
UPSTREAM_SHA="189b4a58d49d332d2ce8267921f7cab5b813ea5c"
# Each build gets its own directory; never remove a previous checkout.
SRC="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/family-tv-src.XXXXXX")"
git -C "$SRC" init -q
git -C "$SRC" remote add origin "$UPSTREAM"
git -C "$SRC" fetch --depth 1 origin "$UPSTREAM_SHA"
git -C "$SRC" checkout --detach FETCH_HEAD
python3 "$CUSTOM_DIR/scripts/customize-tv.py" "$SRC" --repo "$CUSTOM_DIR"
python3 "$CUSTOM_DIR/scripts/test-tv-regressions.py" "$SRC"
python3 "$CUSTOM_DIR/scripts/prepare-media3.py" "$SRC"
cd "$SRC"
# 上游把 FreeBox 配对弹窗布局只放在 mobile flavor，但对应 Java 类位于 main，leanback 构建会缺少 ViewBinding。
mkdir -p app/src/leanback/res/layout
if [ ! -f app/src/leanback/res/layout/dialog_free_box_pairing.xml ]; then
  cp app/src/mobile/res/layout/dialog_free_box_pairing.xml app/src/leanback/res/layout/dialog_free_box_pairing.xml
fi

python3 - <<'PY'
from pathlib import Path
p = Path("gradle/wrapper/gradle-wrapper.properties")
p.write_text(p.read_text().replace("mirrors.cloud.tencent.com/gradle/", "services.gradle.org/distributions/"))
PY
chmod +x gradlew
./gradlew --no-daemon :app:assembleLeanbackArm64_v8aRelease :app:assembleLeanbackArmeabi_v7aRelease
OUT="$CUSTOM_DIR/apk-out"
mkdir -p "$OUT"
for ABI in arm64_v8a armeabi_v7a; do
  APK="$(python3 - "$SRC" "$ABI" <<'PY'
from pathlib import Path
import sys
matches = [p for p in (Path(sys.argv[1]) / 'app/build/outputs/apk').rglob('leanback-' + sys.argv[2] + '.apk') if p.parent.name == 'release']
if len(matches) != 1:
    raise SystemExit('Expected exactly one release APK for ' + sys.argv[2])
print(matches[0])
PY
)"
  test -s "$APK" || { echo "Missing release APK: $ABI" >&2; exit 1; }
  cp "$APK" "$OUT/leanback-$ABI-release.apk"
done
python3 "$CUSTOM_DIR/scripts/verify-apks.py" "$OUT"
cp "$CUSTOM_DIR/scripts/media3-lock.json" "$OUT/media3-lock.json"
printf '%s\n' "$UPSTREAM_SHA" > "$OUT/upstream-commit.txt"
printf '%s\n' "${GITHUB_SHA:-local}" > "$OUT/customization-commit.txt"
echo "Both ARM APKs built and verified: $OUT"
