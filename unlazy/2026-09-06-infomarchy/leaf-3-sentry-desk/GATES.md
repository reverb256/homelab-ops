G1: Sentry Infomarchy plugin installed  |  CHECK: ssh -o BatchMode=yes sentry 'ls -d ~/.config/omarchy/plugins/nixfred.infomarchy 2>/dev/null && echo ok'  |  EXPECT: ok
G2: Sentry shell restarted (desk active)  |  CHECK: ssh -o BatchMode=yes sentry 'pgrep -c quickshell'  |  EXPECT: /[1-9]/
G3: Sentry collector emits valid snapshot  |  CHECK: ssh -o BatchMode=yes sentry 'cd ~/.config/omarchy/plugins/nixfred.infomarchy && timeout 90 bun collector.ts --id probe 2>&1 | grep -q "\"host\"" && echo valid'  |  EXPECT: valid
G4: Sentry local desk has SUPER+D binding  |  CHECK: ssh -o BatchMode=yes sentry 'grep -c "Infomarchy" ~/.config/hypr/bindings.lua'  |  EXPECT: /[1-9]/
