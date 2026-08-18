#!/usr/bin/env bash
# Fetches a brand mark for every integration that doesn't ship one yet.
#
# Nango's integration id is our `IntegrationProvider.rawValue` — the same string
# `integration-connect` sends as `allowed_integrations` — so the catalogue Nod
# already authenticates against is also where its logo comes from. Adding a
# provider is: add the case, run this, commit the asset.
#
# At build time rather than at runtime, deliberately. Fetching a logo while the
# app runs would have the desktop client talk to a third party directly for the
# first time (everything else goes through an edge function), draw a stand-in on
# a cold cache, and let a change on somebody else's CDN change Nod's interface
# without review. An asset in the repository is a file somebody looked at.
#
#   ./scripts/fetch-integration-logos.sh            # only what is missing
#   ./scripts/fetch-integration-logos.sh --force    # re-fetch everything
set -euo pipefail

cd "$(dirname "$0")/.."
assets="Nod/Core/Resources/Assets.xcassets"
# Read from the enum itself, so the list can't drift from what the app offers.
# Bounded to that enum's body: the capability and role enums a few lines away
# have cases too, and asking Nango for a logo of "calendar" is how this quietly
# fetched the wrong thing.
providers=$(awk '/^enum IntegrationProvider/ { inside = 1; next }
                 inside && /^}/ { exit }
                 inside && /^    case / { print }' Nod/Core/Storage/IntegrationConnection.swift \
    | sed -E 's/^    case [a-zA-Z]+ = "([a-z-]+)".*/\1/; s/^    case ([a-zA-Z]+).*/\1/' \
    | tr '[:upper:]' '[:lower:]')

force=${1:-}
for provider in $providers; do
    name="Brand$(echo "$provider" | tr -d '-')"
    imageset="$assets/$name.imageset"
    if [[ -d "$imageset" && "$force" != "--force" ]]; then
        echo "· $provider — $name already ships"
        continue
    fi

    url="https://app.nango.dev/images/template-logos/$provider.svg"
    tmp=$(mktemp)
    if ! curl -sfL --max-time 20 "$url" -o "$tmp"; then
        echo "✗ $provider — Nango has no mark at $url; draw one into $name.imageset by hand"
        rm -f "$tmp"
        continue
    fi
    # Nango answers 200 with an HTML miss page for an unknown id, so the file is
    # checked rather than the status code.
    if ! head -c 400 "$tmp" | grep -qi "<svg"; then
        echo "✗ $provider — $url did not return an SVG"
        rm -f "$tmp"
        continue
    fi

    mkdir -p "$imageset"
    mv "$tmp" "$imageset/$provider.svg"
    cat > "$imageset/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "$provider.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true
  }
}
JSON
    echo "✓ $provider — fetched into $name.imageset"
done
