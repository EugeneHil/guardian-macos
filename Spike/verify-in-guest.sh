#!/usr/bin/env bash
# THROWAWAY SPIKE: run INSIDE the VM after activating the extension.
set -u
mkdir -p /tmp/warden-spike
echo "top secret" > /tmp/warden-spike/secret.txt
echo "harmless"   > /tmp/warden-spike/other.txt
echo "--- systemextensionsctl list (expect [activated enabled]):"
systemextensionsctl list | grep -i warden || echo "NOT LISTED"
echo "--- other.txt (expect content):"
cat /tmp/warden-spike/other.txt
echo "--- secret.txt (expect: Operation not permitted):"
cat /tmp/warden-spike/secret.txt
echo "--- kill -9 the extension, then poll until denial returns:"
pid=$(pgrep -f dev.warden.spike.ext | head -1)
echo "ext pid: ${pid:-none}"
[ -n "$pid" ] && sudo kill -9 "$pid"
start=$(date +%s)
while cat /tmp/warden-spike/secret.txt >/dev/null 2>&1; do sleep 0.5; [ $(( $(date +%s) - start )) -gt 60 ] && { echo "no restart within 60s"; exit 1; }; done
echo "denied again after $(( $(date +%s) - start )) s (restart time)"
