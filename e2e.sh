#!/bin/bash
# End-to-end: build, run the probe against fake_heater.py (mc2a, ma5, nfj3lx), check the JSON.
# Note: specs are downloaded from miot-spec.org on first run and cached in
# ~/Library/Application Support/MiHeaterBar/ (same as the app).
set -euo pipefail
cd "$(dirname "$0")"

TOKEN=00112233445566778899aabbccddeeff
BIN=.build/debug/MiHeaterBar
LOG=$(mktemp -t fake_heater)
FAKE=

stop_fake() {
  if [ -n "$FAKE" ]; then kill "$FAKE" 2>/dev/null || true; wait "$FAKE" 2>/dev/null || true; fi
  FAKE=
}
trap stop_fake EXIT

start_fake() {
  python3 fake_heater.py --model "$1" >"$LOG" 2>&1 &
  FAKE=$!
  for _ in $(seq 50); do grep -q listening "$LOG" && return 0; sleep 0.1; done
  echo "fake heater did not start"; cat "$LOG"; exit 1
}

# countdown_set <minutes>: the fake logged a set_properties of countdown-time (3/1) to that value
countdown_set() {
  python3 -c 'import json,sys
for l in open(sys.argv[1]):
    if l.startswith("set_properties "):
        p = json.loads(l.split(" -> ")[0][len("set_properties "):])[0]
        if (p["siid"], p["piid"], p["value"]) == (3, 1, int(sys.argv[2])): sys.exit(0)
sys.exit(1)' "$LOG" "$1"
}

# check <json> <python expression over d>
check() {
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert eval(sys.argv[2]), sys.argv[2]' "$1" "$2" \
    || { echo "FAIL: $2"; echo "$1"; exit 1; }
  echo "ok: $2"
}

swift build

set +e; "$BIN" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] || { echo "FAIL: usage exit $rc"; exit 1; }
echo "ok: usage exit 2"

start_fake zhimi.heater.mc2a
out=$("$BIN" 127.0.0.1 "$TOKEN")
check "$out" 'd["model"]=="zhimi.heater.mc2a" and d["targetRange"]==[18,28] and d["targetStep"]==1'
check "$out" 'd["modes"]==[] and d["hasTemperatureSensor"] is True'
check "$out" 'd["state"]=={"isOn":True,"targetTemperature":20,"currentTemperature":19.5,"mode":None,"oscillating":None}'
check "$out" 'd["hasOscillation"] is False and d["hasCountdown"] is True'
out=$("$BIN" 127.0.0.1 "$TOKEN" --power off --target 25)
check "$out" 'd["state"]["isOn"] is False and d["state"]["targetTemperature"]==25'
set +e; "$BIN" 127.0.0.1 "$TOKEN" --mode 1 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 1 ] || { echo "FAIL: mode on mc2a exit $rc"; exit 1; }
echo "ok: --mode on mc2a exit 1"
stop_fake

start_fake zhimi.heater.ma5
out=$("$BIN" 127.0.0.1 "$TOKEN" --mode 2)
check "$out" 'd["model"]=="zhimi.heater.ma5" and d["targetRange"]==[16,28]'
check "$out" '[m["name"] for m in d["modes"]]==["Auto","LL Heating","Continus Heating"]'
check "$out" 'd["state"]["mode"]==2 and d["state"]["currentTemperature"]==19.0 and d["state"]["isOn"] is True'
out=$("$BIN" 127.0.0.1 "$TOKEN" --target 30.4)
check "$out" 'd["state"]["targetTemperature"]==28 and d["state"]["mode"]==2'
stop_fake

start_fake leshow.heater.nfj3lx
out=$("$BIN" 127.0.0.1 "$TOKEN" --osc on --countdown 60 --mode 2)
check "$out" 'd["model"]=="leshow.heater.nfj3lx" and d["targetRange"]==[22,28]'
check "$out" '[m["name"] for m in d["modes"]]==["Constant Temperature","Heat","Warm","Natural Wind"]'
check "$out" 'd["hasOscillation"] is True and d["hasCountdown"] is True'
check "$out" 'd["state"]=={"isOn":False,"targetTemperature":24,"currentTemperature":19,"mode":2,"oscillating":True}'
countdown_set 60 || { echo "FAIL: countdown 60 not set"; cat "$LOG"; exit 1; }
echo "ok: countdown set to 60"
out=$("$BIN" 127.0.0.1 "$TOKEN" --osc off --countdown 999)
check "$out" 'd["state"]["oscillating"] is False'
countdown_set 480 || { echo "FAIL: countdown not clamped to 480"; cat "$LOG"; exit 1; }
echo "ok: countdown clamped to 480"
# nfj3lx firmware ignores set_properties on "on"; power must go through the toggle action.
out=$("$BIN" 127.0.0.1 "$TOKEN" --power on)
check "$out" 'd["state"]["isOn"] is True'
out=$("$BIN" 127.0.0.1 "$TOKEN" --power on)
check "$out" 'd["state"]["isOn"] is True'
out=$("$BIN" 127.0.0.1 "$TOKEN" --power off)
check "$out" 'd["state"]["isOn"] is False'
stop_fake

echo "E2E PASS"
