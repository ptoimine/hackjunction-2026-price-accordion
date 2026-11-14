#!/usr/bin/env bash
# Run Price Accordion on a real iPhone: server + tunnel + build + install + launch.
#
#   scripts/run-on-phone.sh              do everything
#   scripts/run-on-phone.sh --stop       stop what this script started, put SERVER_URL back to localhost
#   scripts/run-on-phone.sh --help
#
# Options (or environment variables of the same name in capitals):
#   --device ID        iPhone to use (default: the first connected iPhone; see `xcrun devicectl list devices`)
#   --team ID          Apple Developer team id to sign with (default: the one in the Xcode project)
#   --bundle-id ID     bundle identifier (default: the one in the Xcode project; change it if Apple says it is taken)
#   --free-team        sign with the keychain-only entitlements (a free Personal Team cannot sign the Wi-Fi ones;
#                      the glasses' video stream will not work, everything else does)
#   --tunnel-url URL   use this https URL as the server address instead of starting a quick tunnel
#   --no-build         only (re)start the server and tunnel and point the app source at them
#
# What it leaves behind: logs and pids in .run/ (git-ignored), and ios-app/PriceSense/Config.swift with the tunnel
# address in SERVER_URL. Never commit that line: run `scripts/run-on-phone.sh --stop` first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/.run"
CONFIG="$ROOT/ios-app/PriceSense/Config.swift"
PROJECT="$ROOT/ios-app/PriceSense.xcodeproj"
PORT=8000
LOCAL_URL="http://localhost:$PORT"

DEVICE_ID="${DEVICE_ID:-}"; TEAM_ID="${TEAM_ID:-}"; BUNDLE_ID="${BUNDLE_ID:-}"; TUNNEL_URL="${TUNNEL_URL:-}"
FREE_TEAM=0; NO_BUILD=0; STOP=0

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE_ID="$2"; shift 2 ;;
    --team) TEAM_ID="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --tunnel-url) TUNNEL_URL="$2"; shift 2 ;;
    --free-team) FREE_TEAM=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    --stop) STOP=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown option $1 (try --help)" ;;
  esac
done

set_server_url() {  # edit only the SERVER_URL line: other uncommitted edits to Config.swift stay untouched
  sed -i '' -E "s#(static let SERVER_URL = \")[^\"]*(\")#\1$1\2#" "$CONFIG"
  grep -q "static let SERVER_URL = \"$1\"" "$CONFIG" || die "could not set SERVER_URL in $CONFIG"
}

stop_pid() {  # stop_pid <name>
  local f="$RUN/$1.pid"
  if [ -f "$f" ]; then
    local pid; pid="$(cat "$f")"
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null && say "stopped $1 (pid $pid)"; fi
    rm -f "$f"
  fi
}

if [ "$STOP" = 1 ]; then
  stop_pid tunnel; stop_pid server
  set_server_url "$LOCAL_URL"
  say "SERVER_URL is back to $LOCAL_URL (the app already on the phone keeps its old address and will stop reaching the server)"
  exit 0
fi

mkdir -p "$RUN"

# ---------------------------------------------------------------- 1. what must be there
say "Checking requirements"
for tool in uv xcodebuild xcrun curl python3; do command -v "$tool" >/dev/null || die "$tool is not installed (see README: Requirements)"; done
[ -n "$TUNNEL_URL" ] || command -v cloudflared >/dev/null || die "cloudflared is not installed: brew install cloudflared"
[ -f "$ROOT/.env" ] || die ".env is missing: copy .env.example to .env and fill in the keys (README: Setup)"
for key in NVIDIA_API_KEY NEMOTRON_MODEL CONTEXT_DEV_API_KEY; do
  grep -Eq "^$key=.+" "$ROOT/.env" || die "$key is empty in .env"
done
[ -f "$ROOT/data/spankki/monthly.csv" ] || warn "data/spankki/monthly.csv is missing: the Coach screen will say the money data is not built (README: Money data)"

# ------------------------------------------------------------------ 2. the phone
if [ "$NO_BUILD" = 0 ]; then
  say "Looking for the iPhone"
  if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null | grep -E ' connected ' | grep -E 'iPhone' \
      | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1 || true)"
  fi
  [ -n "$DEVICE_ID" ] || die "no connected iPhone: plug it in with a cable, unlock it, tap Trust, then check \`xcrun devicectl list devices\` says connected"
  echo "device $DEVICE_ID"
fi

# ---------------------------------------------------------------- 3. server
say "Server"
if curl -sf "$LOCAL_URL/health" >/dev/null; then
  echo "already running on $LOCAL_URL"
else
  (cd "$ROOT/server" && nohup uv run uvicorn main:app --port "$PORT" >"$RUN/server.log" 2>&1 & echo $! >"$RUN/server.pid")
  for _ in $(seq 1 40); do curl -sf "$LOCAL_URL/health" >/dev/null && break; sleep 1; done
  curl -sf "$LOCAL_URL/health" >/dev/null || { tail -20 "$RUN/server.log"; die "the server did not start (log above, and $RUN/server.log)"; }
  echo "started (log: .run/server.log)"
fi
curl -s "$LOCAL_URL/health"; echo

# ---------------------------------------------------------------- 4. tunnel
say "Tunnel (the phone reaches the server on your Mac through it)"
if [ -z "$TUNNEL_URL" ]; then
  stop_pid tunnel
  nohup cloudflared tunnel --url "$LOCAL_URL" >"$RUN/tunnel.log" 2>&1 &
  echo $! >"$RUN/tunnel.pid"
  for _ in $(seq 1 40); do
    TUNNEL_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$RUN/tunnel.log" | head -1 || true)"
    [ -n "$TUNNEL_URL" ] && grep -q 'Registered tunnel connection' "$RUN/tunnel.log" && break
    sleep 1
  done
  [ -n "$TUNNEL_URL" ] || { tail -20 "$RUN/tunnel.log"; die "no tunnel address from cloudflared (log above)"; }
fi
# right after it registers the address answers with Cloudflare error 1033 for a few seconds: wait until it really works
for _ in $(seq 1 45); do curl -sf "$TUNNEL_URL/health" >/dev/null && break; sleep 2; done
curl -sf "$TUNNEL_URL/health" >/dev/null || die "$TUNNEL_URL does not reach the server (is the server on port $PORT?)"
echo "$TUNNEL_URL reaches the server"
set_server_url "$TUNNEL_URL"

if [ "$NO_BUILD" = 1 ]; then say "SERVER_URL set; not building (--no-build)"; exit 0; fi

# ---------------------------------------------------------------- 5. build, install, launch
say "Building for the iPhone (first time: Xcode may ask for your keychain password or sign-in)"
ARGS=(-project "$PROJECT" -scheme PriceSense -configuration Debug -destination "id=$DEVICE_ID"
      -derivedDataPath "$RUN/derived" -allowProvisioningUpdates)
[ -n "$TEAM_ID" ] && ARGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
[ -n "$BUNDLE_ID" ] && ARGS+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
[ "$FREE_TEAM" = 1 ] && ARGS+=("CODE_SIGN_ENTITLEMENTS=PriceSense/PriceSense.freeteam.entitlements")
if ! xcodebuild "${ARGS[@]}" build >"$RUN/build.log" 2>&1; then
  grep -E 'error:' "$RUN/build.log" | sort -u | head -8
  die "the build failed (full log: .run/build.log). Signing errors: see README, section Signing"
fi
APP="$(find "$RUN/derived/Build/Products" -maxdepth 2 -name 'PriceSense.app' | head -1)"
[ -d "$APP" ] || die "built app not found under .run/derived"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

say "Installing $BUNDLE"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >"$RUN/install.log" 2>&1 \
  || { tail -8 "$RUN/install.log"; die "install failed. Is the phone unlocked? First install of your own build: iPhone Settings > General > VPN & Device Management > trust your developer certificate"; }

say "Launching"
for attempt in 1 2 3; do  # the first launch right after an install sometimes only acquires the device
  if xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE" 2>&1 | tee "$RUN/launch.log" | grep -q 'Launched application'; then
    LAUNCHED=1; break
  fi
  sleep 2
done
[ "${LAUNCHED:-0}" = 1 ] || { tail -5 "$RUN/launch.log"; die "could not launch: unlock the phone and open Price Sense by hand"; }

say "Done"
cat <<DONE
  app on the phone : $BUNDLE
  server address   : $TUNNEL_URL  (changes whenever the tunnel restarts)
  logs             : .run/server.log  .run/tunnel.log  .run/build.log
  to stop          : scripts/run-on-phone.sh --stop
  Config.swift now has the tunnel address in SERVER_URL. Do not commit that line (--stop puts it back).
DONE
