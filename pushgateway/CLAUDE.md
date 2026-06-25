# CLAUDE.md — PushGateway / GTNH Fluid Alerts

This file explains how the GTNH (GregTech: New Horizons) fluid-level alerts in
`prometheusrule.yaml` are derived, so the thresholds can be recalculated
correctly whenever the reactor setup, fuel tier, or alert policy changes.

## What these alerts do

The in-game AE2 network pushes fluid stock levels into PushGateway as the
`ae2_fluid_amount{name="..."}` metric (units: **mB**). The `ae2-fluid-alerts`
`PrometheusRule` fires a warning to Discord when a monitored fluid drops below a
threshold representing a fixed amount of **remaining runtime**.

**Alert policy: fire when a fluid has less than 7 days of supply left, assuming
all 5 reactors draw continuously.**

(The battery alert, `GTNHBatteryLow`, is a percentage-of-capacity check and is
**not** derived from fluid rates.)

## Where the numbers come from

The consumption rates come from the **"Summary" table** on the GTNH wiki:

  https://wiki.gtnewhorizons.com/wiki/Large_Naquadah_Reactor

The deployed reactors run the **Naq Fuel Mk-II** configuration (fuel = Naq Fuel
Mk-II, coolant = Cryotheum, booster = Separation Catalyst). There are **5
reactors** drawing from the shared AE2 fluid stock, so total draw is 5× the
per-reactor wiki rate. The exact rates, reactor count, and `name` labels live in
`calculate_alert_thresholds.py` (the `FLUIDS` table and `REACTOR_COUNT`) — that
script is the single source of truth, not this prose.

### Unit conventions

- In GTNH, **1 L = 1 mB**, and `ae2_fluid_amount` is reported in **mB**, so the
  wiki's `L/s` rate is numerically the same as **mB per second**.
- Rates are **per real-world second**, assuming the reactors run continuously
  (the conservative, worst-case assumption for "how long will it last").
- 7 days = 7 × 24 × 60 × 60 = **604,800 seconds**, and the draw is `REACTOR_COUNT`
  reactors at once, so
  `threshold_mB = rate_L_per_s × REACTOR_COUNT × 604800` (= `rate_L_per_s × 3024000`
  at 5 reactors).

## How to (re)calculate — ALWAYS use the Python script, never compute by hand

Do **not** do this arithmetic by hand. The committed script
[`calculate_alert_thresholds.py`](./calculate_alert_thresholds.py) is the source
of truth and is auditable and reproducible. To recalculate:

1. Update the `FLUIDS` table at the top of `calculate_alert_thresholds.py` from
   the wiki Summary table — each entry is
   `(display name, ae2_fluid_amount "name" label, rate L/s, current threshold mB)`.
   (Change `ALERT_WINDOW_SECONDS` too if the runtime-window policy changes.)
2. Run it:

   ```bash
   python3 calculate_alert_thresholds.py
   ```

3. Copy each **Proposed threshold** into the matching alert's `expr` in
   `prometheusrule.yaml`, and update the human-readable `(threshold: …)` text in
   that alert's `description` annotation to match.

The script also prints an **audit** of how long the thresholds currently in
`prometheusrule.yaml` last, so you can verify a change had the intended effect.

## When to update

Recalculate (by editing `FLUIDS` and re-running the script) whenever:

- The reactor's **fuel tier** changes (Mk-II → Mk-III, etc.) — every rate changes.
- The **coolant** or **booster** fluid changes — different rate, and the `name`
  label in both the script and `prometheusrule.yaml` must change too.
- The **alert window** changes — edit `ALERT_WINDOW_SECONDS` in the script.
- The **number of reactors** changes — edit `REACTOR_COUNT` in the script.
- The wiki Summary table values change (game balance patches).
