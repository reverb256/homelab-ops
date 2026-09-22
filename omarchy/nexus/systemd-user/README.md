# nexus user units

Units that must run as the `j_kro` user (not root), because their launchers are
per-user tooling: `~/services/*.sh`, per-user venvs, `uv`, `KUBECONFIG` in $HOME.

Install (idempotent):

    install -Dm644 alertmanager-mcp.service godot-mcp.service pihole-mcp.service trading-mcp.service \
        ~/.config/systemd/user/
    install -Dm755 ../bin/alertmanager-mcp.sh ~/services/alertmanager-mcp.sh
    systemctl --user daemon-reload && systemctl --user enable --now alertmanager-mcp.service

Notes on `alertmanager-mcp` — the fragile one:

- It reaches Alertmanager through `kubectl port-forward svc/vmalertmanager-... 19093:9093`
  because vmalertmanager is a HEADLESS service with no ClusterIP. The forward is a child of
  the unit; if it orphans, port 19093 stays bound by a dead process and the unit restart-loops
  (or, worse, keeps serving with no backend). Symptom seen 2026-09-22: every `get_alerts` call
  failed while the unit looked `active`. Diagnosis is one command:
      ss -ltnp | grep -E '19093|8797'
  Fix is: kill the orphan, `systemctl --user restart alertmanager-mcp`.
- The listed port is 19093, not 9093. Checking 9093 will report a false outage.
