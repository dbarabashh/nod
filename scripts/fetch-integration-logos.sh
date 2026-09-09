#!/usr/bin/env bash
# Fetches a brand mark for every integration that doesn't ship one yet.
#
# The broker's app catalogue carries a logo for every app it can authorize, so
# the catalogue Nod already authenticates against is also where its mark comes
# from. Adding a provider is: add the case, run this, commit the asset.
#
# At build time rather than at runtime, deliberately. Fetching a logo while the
# app runs would have the desktop client talk to a third party directly for the
# first time (everything else goes through an edge function), draw a stand-in on
# a cold cache, and let a change on somebody else's CDN change Nod's interface
# without review. An asset in the repository is a file somebody looked at.
#
# Needs a Pipedream API key: `PIPEDREAM_API_KEY`, or the one `pd login` left in
# ~/.config/pipedream/config.
#
#   ./scripts/fetch-integration-logos.sh            # only what is missing
#   ./scripts/fetch-integration-logos.sh --force    # re-fetch everything
set -euo pipefail

cd "$(dirname "$0")/.."
assets="Nod/Core/Resources/Assets.xcassets"
broker="Nod/Core/Storage/IntegrationConnection.swift"

key=${PIPEDREAM_API_KEY:-}
if [[ -z "$key" && -f "$HOME/.config/pipedream/config" ]]; then
    key=$(awk -F'= ' '/^api_key/ { gsub(/ /, "", $2); print $2 }' "$HOME/.config/pipedream/config")
fi
if [[ -z "$key" ]]; then
    echo "✗ no Pipedream API key — set PIPEDREAM_API_KEY or run 'pd login'" >&2
    exit 1
fi

# Read from the enum itself, so the list can't drift from what the app offers.
# Bounded to that enum's body: the capability and role enums a few lines away
# have cases too, and asking for a logo of "calendar" is how this quietly
# fetched the wrong thing.
providers=$(awk '/^enum IntegrationProvider/ { inside = 1; next }
                 inside && /^}/ { exit }
                 inside && /^    case / { print }' Nod/Core/Storage/IntegrationConnection.swift \
    | sed -E 's/^    case [a-zA-Z]+ = "([a-z-]+)".*/\1/; s/^    case ([a-zA-Z]+).*/\1/' \
    | tr '[:upper:]' '[:lower:]')

# Our provider name is not the broker's app slug. `brokerSlug` is the one place
# that knows both, and it is Swift rather than the edge functions because that is
# where the enum this iterates already lives.
slug_for() {
    awk -v want="$1" '
        /var brokerSlug: String/ { inside = 1 }
        inside && $0 ~ "case \\." want ":" {
            if (match($0, /"[a-z0-9_]+"/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit }
        }
        inside && /^    \}/ { exit }
    ' "$broker"
    # A provider absent from the switch falls into the `rawValue` arm, so its
    # slug is its own name.
}

force=${1:-}
for provider in $providers; do
    name="Brand$(echo "$provider" | tr -d '-')"
    imageset="$assets/$name.imageset"
    if [[ -d "$imageset" && "$force" != "--force" ]]; then
        echo "· $provider — $name already ships"
        continue
    fi

    slug=$(slug_for "$provider")
    [[ -n "$slug" ]] || slug="$provider"

    url=$(curl -sfL --max-time 20 "https://api.pipedream.com/v1/apps/$slug" \
        -H "Authorization: Bearer $key" \
        | python3 -c 'import json,sys
try: print((json.load(sys.stdin).get("data") or {}).get("img_src") or "")
except Exception: print("")')
    if [[ -z "$url" ]]; then
        echo "✗ $provider — the catalogue has no mark for $slug; draw one into $name.imageset by hand"
        continue
    fi

    tmp=$(mktemp)
    if ! curl -sfL --max-time 20 "$url" -o "$tmp"; then
        echo "✗ $provider — could not fetch $url"
        rm -f "$tmp"
        continue
    fi
    # SVG or nothing. The catalogue serves a raster mark for some apps, and a
    # PNG dropped into an imageset that everything else draws at 17pt is a
    # blurred logo next to three crisp ones — worse than the Nucleo stand-in,
    # and harder to notice. It also catches a CDN answering 200 with an HTML
    # miss page, which is why the file is checked rather than the status code.
    if ! head -c 400 "$tmp" | grep -qi "<svg"; then
        echo "✗ $provider — the catalogue's mark for $slug is not vector; draw one into $name.imageset by hand"
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
