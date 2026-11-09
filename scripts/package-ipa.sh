#!/usr/bin/env bash
# Packages an unsigned AdBlock.app into IPAs ready to be re-signed by a
# sideloading tool (iLoader, SideStore, AltStore, Sideloadly, ...).
#
# The binaries are ad-hoc signed with their entitlements, so the tool knows
# which capabilities (App Groups, Network Extension) to request when it
# signs with your Apple ID.
#
#   AdBlock.ipa              everything, needs a PAID developer account
#                            (the Network Extension is not allowed otherwise)
#   AdBlock-FreeAccount.ipa  without the "block in apps" VPN extension, works
#                            with a free Apple ID (use the DNS profile instead)
#
# usage: scripts/package-ipa.sh path/to/AdBlock.app output-dir
set -euo pipefail

APP="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GROUP="$(awk '/APP_GROUP_ID:/ { print $2; exit }' "$ROOT/project.yml")"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Entitlements with the App Group build setting expanded.
mkdir -p "$WORK/ent"
for file in "$ROOT"/Config/*.entitlements; do
  sed "s/\$(APP_GROUP_ID)/$GROUP/g" "$file" > "$WORK/ent/$(basename "$file")"
done
cp "$WORK/ent/AdBlock.entitlements" "$WORK/ent/AdBlock-free.entitlements"
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.networking.networkextension" "$WORK/ent/AdBlock-free.entitlements"

sign() { # bundle [entitlements]
  if [[ -n "${2:-}" ]]; then
    codesign --force --sign - --timestamp=none --entitlements "$2" "$1"
  else
    codesign --force --sign - --timestamp=none "$1"
  fi
}

package() { # name app-entitlements include-tunnel(yes/no)
  local name="$1" app_entitlements="$2" tunnel="$3"
  local stage="$WORK/$name"
  mkdir -p "$stage/Payload"
  cp -R "$APP" "$stage/Payload/AdBlock.app"
  local bundle="$stage/Payload/AdBlock.app"

  if [[ "$tunnel" == "no" ]]; then
    rm -rf "$bundle/PlugIns/PacketTunnel.appex"
  else
    sign "$bundle/PlugIns/PacketTunnel.appex" "$WORK/ent/PacketTunnel.entitlements"
  fi
  for blocker in ContentBlockerAds ContentBlockerPrivacy ContentBlockerAnnoyances; do
    sign "$bundle/PlugIns/$blocker.appex" "$WORK/ent/$blocker.entitlements"
  done
  sign "$bundle/PlugIns/YouTubeExtension.appex"
  sign "$bundle" "$app_entitlements"

  (cd "$stage" && zip -qry -X "$OUT/$name.ipa" Payload)
  echo "Created $OUT/$name.ipa ($(du -h "$OUT/$name.ipa" | cut -f1))"
  codesign -d --entitlements :- "$bundle" 2>/dev/null | grep -A2 application-groups || true
}

package AdBlock "$WORK/ent/AdBlock.entitlements" yes
package AdBlock-FreeAccount "$WORK/ent/AdBlock-free.entitlements" no
