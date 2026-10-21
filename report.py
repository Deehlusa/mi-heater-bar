#!/usr/bin/env python3
"""Markdown report from the MiHeaterBar CSV logs.

Usage: python3 -I report.py [--days 7] [--price 0.14] [--dir <csv folder>] [--log <csv>] [--out [file.md]]
Energy figures are estimates from the logged mode (the heater doesn't meter power).
"""
import argparse
import csv
import glob
import os
import sys
from datetime import date, datetime, timedelta

MAX_GAP = 120  # seconds; longer gaps between rows are app/Mac downtime, not heater time
NIGHT_HOURS = range(0, 7)
MODE_LABEL = {"Constant Temperature": "Constant", "Heat": "Heat", "Warm": "Warm", "Natural Wind": "Fan"}
DEFAULT_DIR = os.path.expanduser("~/Library/Application Support/MiHeaterBar")


def watts(on, mode, room, target):
    """Same rules as HeaterKit EnergyEstimate.watts."""
    if not on:
        return 0
    if mode == "Warm":
        return 1400
    if mode == "Natural Wind":
        return 12
    if mode == "Constant Temperature" and room is not None and target is not None:
        return 2000 if room < target else 1400 if room == target else 12
    return 2000


def num(s):
    return float(s) if s else None


def fmt(x, digits=1):
    return f"{x:,.{digits}f}"


def load(paths):
    rows = []
    for path in paths:
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                try:
                    ts = datetime.fromisoformat(r["ts"])
                except (KeyError, TypeError, ValueError):
                    continue
                rows.append({
                    "ts": ts, "room": num(r["room_c"]), "on": r["on"] == "1", "mode": r["mode"] or None,
                    "target": num(r["device_target"]), "auto": r["auto"] == "1", "auto_target": num(r["auto_target"]),
                    "action": r["action"], "source": r["source"], "error": r["error"],
                })
    rows.sort(key=lambda r: r["ts"])
    return rows


def intervals(rows):
    """(a, b, dt) for consecutive state rows; dt capped at MAX_GAP, raw gap kept for rate math."""
    for a, b in zip(rows, rows[1:]):
        raw = (b["ts"] - a["ts"]).total_seconds()
        if raw > 0:
            yield a, b, min(raw, MAX_GAP), raw


def runs(rows):
    """Consecutive runs of equal power state: {on, secs, auto at the run's start}."""
    out = []
    for a, b, dt, _ in intervals(rows):
        if out and out[-1]["on"] == a["on"]:
            out[-1]["secs"] += dt
        else:
            out.append({"on": a["on"], "secs": dt, "auto": a["auto"]})
    return out


def report(rows, days, price):
    end = rows[-1]["ts"]
    rows = [r for r in rows if r["ts"] >= end - timedelta(days=days)]
    state = [r for r in rows if r["source"] != "error"]
    errors = sum(r["source"] == "error" for r in rows)
    manual = sum(r["source"] == "manual" for r in rows)
    span_h = sum(dt for _, _, dt, _ in intervals(state)) / 3600

    on_s, kwh, rate = {}, {}, {}  # per mode
    cool = [0.0, 0.0]  # delta °C, seconds while off
    auto_s = band_s = night_on_s = 0.0
    for a, b, dt, raw in intervals(state):
        mode = a["mode"] or "—"
        if a["on"]:
            on_s[mode] = on_s.get(mode, 0) + dt
            kwh[mode] = kwh.get(mode, 0) + watts(True, a["mode"], a["room"], a["target"]) * dt / 3.6e6
            if a["ts"].hour in NIGHT_HOURS:
                night_on_s += dt
        if a["auto"]:
            auto_s += dt
            if a["room"] is not None and a["auto_target"] is not None and abs(a["room"] - a["auto_target"]) <= 1:
                band_s += dt
        if raw <= MAX_GAP and a["room"] is not None and b["room"] is not None:
            acc = rate.setdefault(mode, [0.0, 0.0]) if a["on"] else cool
            acc[0] += b["room"] - a["room"]
            acc[1] += raw

    total_on_h = sum(on_s.values()) / 3600
    total_kwh = sum(kwh.values())
    temps = [r["room"] for r in state if r["room"] is not None]
    rs = runs(state)
    ons = [r["secs"] for r in rs if r["on"]]
    # Completed auto pauses: off runs that started with auto on, between two on runs.
    pauses = [r["secs"] for i, r in enumerate(rs) if not r["on"] and r["auto"] and 0 < i < len(rs) - 1]
    starts = sum(1 for a, b in zip(state, state[1:]) if not a["on"] and b["on"])
    per_h = lambda acc: acc[0] / (acc[1] / 3600) if acc[1] >= 600 else None
    span_days = max(span_h / 24, 1 / 24)
    month_cost = total_kwh * price / span_days * 30

    out = [f"# Heater report · {rows[0]['ts']:%Y-%m-%d %H:%M} → {end:%Y-%m-%d %H:%M}", ""]
    out += [f"> Energy and cost are **estimates** based on the logged mode (Heat 2000 W, Warm 1400 W, "
            f"Fan 12 W; Constant depends on the distance to the target). The heater doesn't measure power. "
            f"Time covered by the log: {fmt(span_h)} h.", ""]

    out += ["## Totals", "", "| Mode | Hours on | kWh | € |", "|---|---:|---:|---:|"]
    for mode in sorted(on_s, key=on_s.get, reverse=True):
        out.append(f"| {MODE_LABEL.get(mode, mode)} | {fmt(on_s[mode] / 3600)} | {fmt(kwh[mode], 2)} | {fmt(kwh[mode] * price, 2)} |")
    out += [f"| **Total** | **{fmt(total_on_h)}** | **{fmt(total_kwh, 2)}** | **{fmt(total_kwh * price, 2)}** |", "",
            f"Price: {fmt(price, 3)} €/kWh · projected cost/month: **€{fmt(month_cost, 2)}**", ""]

    out += ["## Room temperature", ""]
    if temps:
        out.append(f"- Average {fmt(sum(temps) / len(temps))} °C · min {fmt(min(temps))} °C · max {fmt(max(temps))} °C")
    out.append(f"- Auto active {fmt(auto_s / 3600)} h; within target ±1 °C: "
               + (f"**{fmt(100 * band_s / auto_s, 0)}%**" if auto_s else "—"))
    out.append("")

    out += ["## Cycles", "", f"- Starts: {starts}",
            f"- Average on time: {fmt(sum(ons) / len(ons) / 60, 0)} min" if ons else "- Average on time: —",
            f"- Average Auto pause: {fmt(sum(pauses) / len(pauses) / 60, 0)} min ({len(pauses)} pauses)"
            if pauses else "- Average Auto pause: —", ""]

    out += ["## Heating/cooling rates", "", "| State | °C/h | Hours measured |", "|---|---:|---:|"]
    for mode, acc in sorted(rate.items()):
        r = per_h(acc)
        out.append(f"| On · {MODE_LABEL.get(mode, mode)} | {fmt(r, 2) if r is not None else '—'} | {fmt(acc[1] / 3600)} |")
    r = per_h(cool)
    out += [f"| Off | {fmt(r, 2) if r is not None else '—'} | {fmt(cool[1] / 3600)} |", "",
            "_Whole-degree sensor (°C): rates over short windows are noisy._", ""]

    out += ["## Interventions and errors", "", f"- Manual interventions: {manual}",
            f"- Communication errors: {errors} ({fmt(100 * errors / len(rows), 1)}% of rows)", ""]

    tips = []
    warm = per_h(rate.get("Warm", [0, 0]))
    if warm is not None and warm <= 0.2 and rate["Warm"][1] >= 3600:
        tips.append(f"Warm barely heats the room ({fmt(warm, 2)} °C/h): **lower `boostGap`** (e.g. 1.5 → 1.0) "
                    "so Auto switches to Heat sooner.")
    short = [p for p in pauses if p < 600]
    if len(pauses) >= 3 and len(short) / len(pauses) >= 0.3:
        tips.append(f"{len(short)} of {len(pauses)} pauses lasted < 10 min: **raise `band`** (e.g. 0.5 → 1.0) "
                    "for longer cycles.")
    if total_on_h >= 1 and night_on_s / 3600 >= 0.25 * total_on_h:
        tips.append(f"{fmt(night_on_s / 3600)} h on between 00:00 and 07:00 ({fmt(100 * night_on_s / 3600 / total_on_h, 0)}% of total): "
                    "consider turning Auto off at night or lowering the target.")
    if rows and errors / len(rows) >= 0.05:
        tips.append("Many communication errors: check the heater's Wi-Fi and use a fixed IP.")
    tips.append(f"Projected cost: **€{fmt(month_cost, 2)}/month** at this period's rate.")
    out += ["## Recommendations", ""] + [f"- {t}" for t in tips]
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--days", type=float, default=7, help="last N days up to the latest entry (default 7)")
    ap.add_argument("--price", type=float, default=0.14, help="€/kWh (default 0.14)")
    ap.add_argument("--dir", default=DEFAULT_DIR, help="folder with log-YYYY-MM.csv")
    ap.add_argument("--log", help="a single CSV (ignores --dir)")
    ap.add_argument("--out", nargs="?", const=f"report-{date.today():%Y-%m-%d}.md", help="also write to a file")
    args = ap.parse_args()

    paths = [args.log] if args.log else sorted(glob.glob(os.path.join(args.dir, "log-*.csv")))
    rows = load(paths)
    if not rows:
        sys.exit(f"no data in {', '.join(paths) or args.dir}")
    md = report(rows, args.days, args.price)
    sys.stdout.write(md)
    if args.out:
        with open(args.out, "w") as f:
            f.write(md)


if __name__ == "__main__":
    main()
