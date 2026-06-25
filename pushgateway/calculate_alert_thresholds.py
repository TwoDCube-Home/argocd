#!/usr/bin/env python3
"""Calculate and audit GTNH fluid-level alert thresholds for the PushGateway.

This module is the single source of truth for the numbers in
``prometheusrule.yaml`` (the ``ae2-fluid-alerts`` PrometheusRule). It exists so
the thresholds are never computed by hand: the arithmetic is reproducible and
auditable, and the consumption rates that drive it live in one obvious place.

Why these numbers exist
-----------------------
The in-game AE2 network pushes fluid stock levels into PushGateway as the
``ae2_fluid_amount{name="..."}`` metric (units: mB). Each fluid alert fires when
its stock drops below a threshold that represents a fixed amount of *remaining
runtime* -- by policy, **one day of continuous draw across all reactors**.

Where the rates come from
-------------------------
The consumption rates are taken from the "Summary" table of the GTNH wiki page
for the Large Naquadah Reactor:

    https://wiki.gtnewhorizons.com/wiki/Large_Naquadah_Reactor

The deployed reactors run the **Naq Fuel Mk-II** configuration, so the rates
below are that row of the Summary table -- *per reactor*; total draw is
``REACTOR_COUNT`` times these rates. Update ``FLUIDS`` whenever the fuel tier,
coolant, booster, or wiki values change (and ``REACTOR_COUNT`` whenever reactors
are added or removed), then re-run this script and copy the results into
``prometheusrule.yaml``.

Unit conventions
----------------
- In GTNH, 1 L = 1 mB, and ``ae2_fluid_amount`` is reported in mB, so a wiki
  ``L/s`` rate is numerically identical to mB per second.
- Rates are per real-world second, assuming the reactor runs continuously. This
  is the conservative (worst-case) assumption for "how long will it last".

Usage
-----
    python3 calculate_alert_thresholds.py

Prints the proposed thresholds for the configured ``ALERT_WINDOW_SECONDS`` (to
write into the alert ``expr``) and an audit of how long the thresholds currently
in ``prometheusrule.yaml`` actually last.
"""

from __future__ import annotations

from dataclasses import dataclass

SECONDS_PER_DAY = 24 * 60 * 60          # 86,400
SECONDS_PER_WEEK = 7 * SECONDS_PER_DAY  # 604,800

#: Number of reactors drawing from the shared AE2 fluid stock. Each reactor runs
#: the same configuration, so total draw is this many times the per-reactor wiki
#: rate in ``FLUIDS``.
REACTOR_COUNT = 5

#: Alert policy: fire when a fluid has less than this much runtime left.
ALERT_WINDOW_SECONDS = SECONDS_PER_WEEK


@dataclass(frozen=True)
class Fluid:
    """One monitored fluid and the data needed to derive its alert threshold.

    Attributes:
        display: Human-readable label used in this script's output only.
        metric_name: The exact ``name`` label on the ``ae2_fluid_amount`` series
            (must match the alert ``expr`` in ``prometheusrule.yaml``).
        rate_l_per_s: Per-reactor consumption rate in L/s, from the wiki Summary
            table. Since 1 L = 1 mB, this is also a single reactor's draw in mB
            per second; total draw is this times ``REACTOR_COUNT``.
        current_threshold_mb: The threshold currently deployed in
            ``prometheusrule.yaml``, used only by the audit. Set to ``None`` for
            a fluid that does not yet have an alert.
    """

    display: str
    metric_name: str
    rate_l_per_s: float
    current_threshold_mb: int | None

    def threshold_mb(self, window_seconds: int = ALERT_WINDOW_SECONDS) -> int:
        """Return the threshold (mB) for ``window_seconds`` of continuous draw.

        Accounts for all ``REACTOR_COUNT`` reactors drawing simultaneously.
        """
        return round(self.rate_l_per_s * REACTOR_COUNT * window_seconds)

    def current_runtime_days(self) -> float | None:
        """Return how many days the *current* threshold lasts, or ``None``."""
        if self.current_threshold_mb is None:
            return None
        draw_per_s = self.rate_l_per_s * REACTOR_COUNT
        return self.current_threshold_mb / draw_per_s / SECONDS_PER_DAY


# Naq Fuel Mk-II configuration of the Large Naquadah Reactor.
# (display, ae2_fluid_amount name label, rate L/s from wiki, current mB threshold)
FLUIDS: list[Fluid] = [
    Fluid("Cryotheum (coolant)",           "cryotheum",                         1000.0, 3_024_000_000),
    Fluid("Naq Fuel Mk-II (fuel)",         "naquadah based liquid fuel mkii",      4.57,    13_819_680),
    Fluid("Separation Catalyst (booster)", "molten.atomic separation catalyst",   20.0,    60_480_000),
]


def main() -> None:
    """Print the proposed thresholds for the configured window and audit the deployed ones."""
    window_days = ALERT_WINDOW_SECONDS / SECONDS_PER_DAY
    print(f"Reactors: {REACTOR_COUNT}")
    print(f"Alert window: {ALERT_WINDOW_SECONDS:,} seconds ({window_days:g} days)\n")

    print(f"=== Proposed thresholds ({window_days:g}-day supply, {REACTOR_COUNT} reactors) ===")
    print(f"{'Fluid':<32}{'Rate L/s':>10}{'Threshold mB':>16}")
    for f in FLUIDS:
        print(f"{f.display:<32}{f.rate_l_per_s:>10}{f.threshold_mb():>16,}")

    print("\n=== Audit: how long do CURRENT thresholds last ===")
    print(f"{'Fluid':<32}{'Rate L/s':>10}{'Current mB':>16}{'Lasts (days)':>14}")
    for f in FLUIDS:
        days = f.current_runtime_days()
        days_str = "n/a" if days is None else f"{days:.2f}"
        current_str = "n/a" if f.current_threshold_mb is None else f"{f.current_threshold_mb:,}"
        print(f"{f.display:<32}{f.rate_l_per_s:>10}{current_str:>16}{days_str:>14}")


if __name__ == "__main__":
    main()
