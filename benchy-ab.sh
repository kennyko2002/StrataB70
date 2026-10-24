#!/usr/bin/env bash
# benchy-ab.sh - run benchy v1 twice on the served model, back to back:
#
#   A: the serve config as it is now, with its "env" block
#      (STRATA_VERIFY_NO_HOST=0, STRATA_VERIFY_DEVICE_PLAN=0 -> neither is passed to the engine)
#   B: the same config with the "env" block removed
#      (strata-sycl.sh's own defaults apply: STRATA_VERIFY_DEVICE_PLAN=1, STRATA_VERIFY_NO_HOST=1)
#
# Everything else is identical: the same engine args, the v1 prompts, 256 greedy tokens, a fresh engine process
# per run, the page cache dropped before each run.
#
# The served model on :8080 is stopped for the whole run and started again at the end, warm-up included.
set -uo pipefail

repo=/home/knyi/Strata_B70
outbase=$repo/sycl/benchy-results
stamp=$(date +%Y%m%d-%H%M)
dir=$outbase/ab-$stamp
mkdir -p "$dir"
log=$dir/run.log

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$log"; }
vram_mb() { python3 -c 'import json;print(int(json.load(open("/run/gpustat.json")).get("vram_used_mb",0)))' 2>/dev/null || echo -1; }

# the model comes back whatever happens - a failed bench must not leave the machine without a server
restart_model() {
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE '^:8080$'; then
        say "8080 is already listening again."
        return 0
    fi
    say "starting the served model again..."
    ( cd "$repo" && nohup ./run-iq3_xxs.sh >> "$dir/serve.log" 2>&1 & disown )
    for _ in $(seq 1 90); do
        sleep 5
        if curl -sf -m 5 http://127.0.0.1:8080/metrics > /dev/null 2>&1; then
            say "8080 is up. done."
            return 0
        fi
    done
    say "WARNING: 8080 did not come back within 450 s - check $dir/serve.log"
}
trap restart_model EXIT

say "benchy A/B ($stamp): model qwen3.8-flash-next-iq3_xxs, Intel Arc, cold page cache"
say "Intel VRAM in use before: $(vram_mb) MB"

say "stopping the served model..."
"$HOME/strata-b70-stop.sh" 2>&1 | tee -a "$log"
for _ in $(seq 1 24); do
    v=$(vram_mb)
    [ "$v" -ge 0 ] && [ "$v" -le 2048 ] && break
    sleep 5
done
say "Intel VRAM after the stop: $(vram_mb) MB"

for variant in A B; do
    if [ "$variant" = A ]; then
        cfg=$repo/strata-iq3_xxs.json
        label=A-configenv
        note="config's env block: STRATA_VERIFY_NO_HOST=0 STRATA_VERIFY_DEVICE_PLAN=0 (neither reaches the engine)"
    else
        cfg=$repo/bench-configs/strata-iq3_xxs-noenv.json
        label=B-noenv
        note="no env block: strata-sycl.sh defaults STRATA_VERIFY_DEVICE_PLAN=1 STRATA_VERIFY_NO_HOST=1"
    fi
    out=$outbase/v1-$stamp-$label
    say "=== variant $label: $note"
    say "out: $out"
    rc=0
    sudo -n python3 "$repo/sycl/tools/perf_matrix.py" --configs "$cfg" --out "$out" 2>&1 | tee -a "$log" || rc=$?
    say "variant $label finished (rc=$rc)"
done

sudo -n chown -R "$USER" "$outbase" 2>/dev/null || true
say "both variants done; $dir/run.log"
