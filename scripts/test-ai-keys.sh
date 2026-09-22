#!/usr/bin/env bash
# Empirically test every Hermes/opencode-consumed AI key: sops-store copy vs
# live ~/.hermes/.env copy. Prints verdicts ONLY — never key values.
set -u
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
SEC="$HOME/Work/Projects/nixos-secrets/secrets"
ENVF="$HOME/.hermes/.env"

store() { sops -d --extract '["'"$2"'"]' "$SEC/$1" 2>/dev/null | tr -d '\n'; }
envv()  { grep -m1 "^$1=" "$ENVF" | cut -d= -f2- | tr -d '\n'; }

code() { # method url extra_header...
  local m=$1 u=$2; shift 2
  curl -s -o /dev/null -w '%{http_code}' -X "$m" "$u" "$@" --max-time 12
}

t() { # label expected_code actual_code
  if [ "$3" = "$2" ]; then echo "$1: OK ($3)"; else echo "$1: FAIL (got $3, want $2)"; fi
}

echo "== OpenRouter =="
OK=$(store ai/openrouter-api-key.yaml data); OE=$(envv OPENROUTER_API_KEY)
t "store" 200 $(code GET https://openrouter.ai/api/v1/key -H "Authorization: Bearer $OK")
t "env  " 200 $(code GET https://openrouter.ai/api/v1/key -H "Authorization: Bearer $OE")

echo "== NVIDIA NIM =="
NK=$(store ai/nvidia-api-key.yaml data); NE=$(envv NVIDIA_API_KEY)
t "store" 200 $(code GET https://integrate.api.nvidia.com/v1/models -H "Authorization: Bearer $NK")
t "env  " 200 $(code GET https://integrate.api.nvidia.com/v1/models -H "Authorization: Bearer $NE")

echo "== OpenCode Zen (zen + go) =="
ZK=$(store ai/opencode-api-key.yaml data); ZE=$(envv OPENCODE_ZEN_API_KEY); ZA=$(envv OPENCODE_API_KEY)
t "store" 200 $(code GET https://opencode.ai/zen/v1/models -H "Authorization: Bearer $ZK")
t "env(zen)" 200 $(code GET https://opencode.ai/zen/v1/models -H "Authorization: Bearer $ZE")
t "env(alias)" 200 $(code GET https://opencode.ai/zen/v1/models -H "Authorization: Bearer $ZA")
GK=$(store ai/opencode-go-api-key.yaml data); GE=$(envv OPENCODE_GO_API_KEY)
t "store(go)" 200 $(code GET https://opencode.ai/zen/go/v1/models -H "Authorization: Bearer $GK")
[ -n "$GE" ] && t "env(go)" 200 $(code GET https://opencode.ai/zen/go/v1/models -H "Authorization: Bearer $GE") || echo "env(go): ABSENT"

echo "== Exa =="
EK=$(store ai/exa-api-key.yaml data); EE=$(envv EXA_API_KEY)
exa_test() { code POST https://api.exa.ai/search -H "x-api-key: $1" -H "Content-Type: application/json" -d '{"query":"connectivity check","numResults":1}'; }
t "store" 200 $(exa_test "$EK")
[ -n "$EE" ] && t "env  " 200 $(exa_test "$EE") || echo "env: ABSENT"

echo "== GitHub PAT =="
GHK=$(store ci/github-token.yaml data); GHE=$(envv GITHUB_TOKEN)
t "store" 200 $(code GET https://api.github.com/user -H "Authorization: Bearer $GHK")
[ -n "$GHE" ] && t "env  " 200 $(code GET https://api.github.com/user -H "Authorization: Bearer $GHE") || echo "env: ABSENT"

echo "== Telegram bot =="
TK=$(store ai/telegram-bot-token.yaml data); TE=$(envv TELEGRAM_BOT_TOKEN)
t "store" 200 $(code GET "https://api.telegram.org/bot$TK/getMe")
if [ -n "$TE" ]; then t "env  " 200 $(code GET "https://api.telegram.org/bot$TE/getMe"); else echo "env: ABSENT"; fi

echo "== KiloCode JWT (local exp check, no network) =="
for src in store env; do
  J=$([ $src = store ] && store ai/kilo-api-key.yaml data || envv KILOCODE_API_KEY)
  python3 - "$src" "$J" <<'EOF'
import base64, json, sys, time
name, jwt = sys.argv[1], sys.argv[2]
try:
    p = jwt.split('.')[1]; p += '=' * (-len(p) % 4)
    claims = json.loads(base64.urlsafe_b64decode(p))
    exp = claims.get('exp'); days=(exp-time.time())/86400
    print(f"{name}: exp in {days:.0f} days -> {'VALID' if days>0 else 'EXPIRED'}")
except Exception as e:
    print(f"{name}: UNPARSEABLE ({e})")
EOF
done



echo "== Nous Research =="
NK=$(envv NOUS_API_KEY)
if [ -n "$NK" ]; then 
  t "env  " 200 $(code GET https://inference-api.nousresearch.com/v1/models -H "Authorization: Bearer $NK")
else 
  echo "env: ABSENT"
fi

echo "== CommandCode =="
CC=$(envv COMMANDCODE_API_KEY)
if [ -n "$CC" ]; then 
  t "env  " 200 $(code GET https://api.commandcode.ai/provider/v1/models -H "Authorization: Bearer $CC")
else 
  echo "env: ABSENT"
fi

echo "== Google/Gemini =="
GG=$(envv GOOGLE_API_KEY)
if [ -n "$GG" ]; then t "env" 200 $(code GET "https://generativelanguage.googleapis.com/v1beta/models?key=$GG"); else echo "env: ABSENT"; fi


echo "== Nous Research =="
NK=$(envv NOUS_API_KEY)
if [ -n "$NK" ]; then 
  t "env  " 200 $(code GET https://inference-api.nousresearch.com/v1/models -H "Authorization: Bearer $NK")
else 
  echo "env: ABSENT"
fi

echo "== CommandCode =="
CC=$(envv COMMANDCODE_API_KEY)
if [ -n "$CC" ]; then t "env" 200 $(code GET https://api.commandcode.ai/v1/models -H "Authorization: Bearer $CC"); else echo "env: ABSENT"; fi
