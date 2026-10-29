#!/bin/zsh
# ios_bundle.sh <built .app> <out dir> [device id]
# Copies the title's files into the iOS app built by CMake, embeds the
# provisioning profile, signs it and, given a device id, installs it.
#   GAME_DIR   the title's directory (default run/hdd0/game/NPEB00121)
#   FLASH_DIR  dev_flash with sys/external/flashMP3.pic (default run/dev_flash)
#   PROFILE    the .mobileprovision for the app's bundle identifier
#   SIGN_ID    the signing identity's SHA-1 (default: the first Apple Development one)
#   ENTITLEMENTS  default port/ios/DiggerHD.entitlements (tvOS: DiggerHD-tvOS.entitlements)
set -e
here=${0:A:h:h}
app_in=$1; out=$2; device=$3
: ${GAME_DIR:=$here/run/hdd0/game/NPEB00121}
: ${FLASH_DIR:=$here/run/dev_flash}
: ${PROFILE:?set PROFILE}
: ${SIGN_ID:=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}
[[ -n $SIGN_ID ]] || { echo "no Apple Development signing identity; set SIGN_ID" >&2; exit 1; }

app=$out/DiggerHD.app
mkdir -p $out
rsync -a --delete $app_in/ $app/
mkdir -p $app/game/NPEB00121 $app/dev_flash
# The title's files. scenes.sdat.dec goes too: the runtime decrypts an EDAT
# into a .dec beside it, and the bundle is read-only on the device.
rsync -aL --delete --exclude '*.unedat' $GAME_DIR/ $app/game/NPEB00121/
rsync -aL --delete $FLASH_DIR/ $app/dev_flash/
# The playtest's reference screens for PAD_AUTOPLAY (tools/make_autoplay_refs.py).
[[ -f $here/run/autoplay-refs.bin ]] && cp $here/run/autoplay-refs.bin $app/
# Shaders translated on the Mac (PS3_SHADER_CACHE=run/shader-cache during a
# playtest), compiled ahead at start-up instead of mid-frame.
if [[ -d ${SHADER_DIR:=$here/run/shader-cache} ]]; then
    rsync -a --delete $SHADER_DIR/ $app/shaders/
fi
# Icons: asset catalogs made from the title's cover (ICON_DIR, default
# run/icon: Assets-ios.xcassets, Assets-tvos.xcassets), compiled by actool
# into Assets.car, their Info.plist keys merged in.
: ${ICON_DIR:=$here/run/icon}
if /usr/libexec/PlistBuddy -c "Print :CFBundleSupportedPlatforms:0" $app/Info.plist | grep -q AppleTVOS; then
    cat_dir=$ICON_DIR/Assets-tvos.xcassets; plat=appletvos; icon="App Icon & Top Shelf Image"; dev=(--target-device tv)
else
    cat_dir=$ICON_DIR/Assets-ios.xcassets; plat=iphoneos; icon=AppIcon; dev=(--target-device iphone --target-device ipad)
fi
if [[ -d $cat_dir ]]; then
    partial=$out/icon-partial.plist
    xcrun actool $cat_dir --compile $app --platform $plat --minimum-deployment-target 17.0 \
        --app-icon "$icon" $dev --output-partial-info-plist $partial --errors --warnings > $out/actool.log
    /usr/libexec/PlistBuddy -c "Merge $partial" $app/Info.plist > /dev/null
fi
cp $PROFILE $app/embedded.mobileprovision
# The app and team identifiers come from the profile, so nothing team-specific
# lives in the repository's entitlements.
ent=$out/entitlements.plist
cp ${ENTITLEMENTS:-$here/port/ios/DiggerHD.entitlements} $ent
prof_ent=$out/profile-entitlements.plist
security cms -D -i $PROFILE | plutil -extract Entitlements xml1 -o $prof_ent -
for k in application-identifier com.apple.developer.team-identifier; do
    v=$(/usr/libexec/PlistBuddy -c "Print :$k" $prof_ent)
    /usr/libexec/PlistBuddy -c "Delete :$k" $ent 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :$k string $v" $ent
done
codesign --force --sign $SIGN_ID --entitlements $ent \
         --timestamp=none --generate-entitlement-der $app
codesign --verify --strict $app
echo "signed: $app ($(du -sh $app | cut -f1))"
if [[ -n $device ]]; then
    xcrun devicectl device install app --device $device $app
fi
