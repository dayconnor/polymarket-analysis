"""Polymarket calibration dashboard.

Reads only committed CSVs: results/ (written by notebooks 01-03) and app/data/
(written by sql/04_dashboard). Nothing here fits a model or touches data/processed,
so the hosted app shows exactly the numbers in the README.

Run locally:  .venv/bin/streamlit run app/streamlit_app.py
"""

import json
from pathlib import Path

import numpy as np
import pandas as pd
import plotly.graph_objects as go
import streamlit as st

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"
APP_DATA = ROOT / "app" / "data"
REPO = "https://github.com/dayconnor/polymarket-analysis"
SITE = "https://polymarket-analysis-cd.streamlit.app/"

st.set_page_config(page_title="Polymarket Calibration", page_icon="📈", layout="wide")

# Validated categorical slots (dataviz reference palette), light and dark steps.
PALETTE = {
    "light": {"series": ["#257de0", "#f47230", "#00b894", "#f2a600", "#ee7fac"],
              "muted": "#666666", "ref": "#b3b3b3"},
    "dark": {"series": ["#338ced", "#e76624", "#00a888", "#d28e05", "#e24d8b"],
             "muted": "#9c9c9c", "ref": "#5c5c5c"},
}
# Colour follows the entity: crypto keeps slot 2 (orange) in every view.
SLOT = {"non-crypto": 0, "crypto": 1, "sports": 0, "politics": 2, "weather": 3, "other": 4,
        "event": 0, "template": 1}
SYMBOL = {"non-crypto": "circle", "crypto": "diamond", "sports": "circle", "politics": "square",
          "weather": "triangle-up", "other": "x", "event": "circle", "template": "diamond"}
HORIZONS = {"1 week": "1w", "1 day": "1d", "1 hour": "1h"}
SUBJECTS = ["crypto", "sports", "politics", "weather", "other"]


def theme():
    try:
        return PALETTE["dark" if st.context.theme.type == "dark" else "light"]
    except Exception:
        return PALETTE["light"]


# Streamlit has no Python API to switch themes, and a [theme] in config.toml would override
# the viewer's choice. So this writes the frontend's own stored preference (localStorage
# "stActiveTheme-<path>-v2", internal to Streamlit 1.67: recheck if Streamlit is upgraded)
# and reloads. First visit defaults to Light; reloads only if the OS had picked Dark.
THEME_JS = """<script>
(() => {
  try {
    const key = `stActiveTheme-${window.location.pathname}-v2`;
    const target = __TARGET__;
    const stored = localStorage.getItem(key);
    if (target) {
      localStorage.setItem(key, JSON.stringify(target));
      window.location.reload();
    } else if (stored === null || stored === '"System"') {
      localStorage.setItem(key, '"Light"');
      if (__IS_DARK__) window.location.reload();
    }
  } catch (e) { /* storage blocked: keep Streamlit's default */ }
})();
</script>"""


def theme_toggle(container):
    dark = theme() is PALETTE["dark"]
    target = None
    if container.button("Light mode" if dark else "Dark mode", key="theme_toggle",
                        icon=":material/light_mode:" if dark else ":material/dark_mode:"):
        target = "Light" if dark else "Dark"
    st.html(THEME_JS.replace("__TARGET__", json.dumps(target))
            .replace("__IS_DARK__", json.dumps(dark)), unsafe_allow_javascript=True)


def color(entity):
    return theme()["series"][SLOT[entity]]


@st.cache_data
def load(name, folder=RESULTS):
    return pd.read_csv(folder / f"{name}.csv")


def ci(est, lo, hi, scale=1.0, digits=3):
    if pd.isna(lo) or pd.isna(hi):
        return f"{est * scale:+.{digits}f}"
    return f"{est * scale:+.{digits}f} [{lo * scale:.{digits}f}, {hi * scale:.{digits}f}]"


def base_layout(fig, x_title, y_title, height=460):
    fig.update_layout(
        height=height, margin=dict(l=10, r=10, t=60, b=10), hovermode="closest",
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="left", x=0,
                    title_text=""),
        xaxis_title=x_title, yaxis_title=y_title)
    return fig


def show(fig, data=None):
    st.plotly_chart(fig, theme="streamlit", width="stretch")
    if data is not None:
        with st.expander("Show data"):
            st.dataframe(data, hide_index=True, width="stretch")


def calibration_fig(series):
    """series: list of (entity, frame with mean_price, win_rate, lo, hi, n)."""
    fig = go.Figure()
    fig.add_trace(go.Scatter(x=[0, 1], y=[0, 1], mode="lines", hoverinfo="skip",
                             line=dict(color=theme()["ref"], width=1), name="perfect calibration"))
    for entity, d in series:
        d = d.sort_values("mean_price")
        small = d["n"] < 30
        fig.add_trace(go.Scatter(
            x=d["mean_price"], y=d["win_rate"], name=entity, mode="lines+markers",
            line=dict(color=color(entity), width=2),
            marker=dict(size=9, color=color(entity), symbol=[
                SYMBOL[entity] + ("-open" if s else "") for s in small]),
            error_y=dict(type="data", symmetric=False, thickness=1.2, width=3,
                         array=d["hi"] - d["win_rate"], arrayminus=d["win_rate"] - d["lo"]),
            customdata=np.c_[d["n"], d["lo"], d["hi"]],
            hovertemplate=(f"<b>{entity}</b><br>mean price %{{x:.3f}}<br>win rate %{{y:.3f}}"
                           "<br>95% CI [%{customdata[1]:.3f}, %{customdata[2]:.3f}]"
                           "<br>%{customdata[0]:,} markets<extra></extra>")))
    base_layout(fig, "mean price (probability)", "observed win frequency", height=520)
    # constrain="domain" shrinks the plot area to stay square instead of widening the range.
    fig.update_xaxes(range=[-0.02, 1.02], constrain="domain")
    fig.update_yaxes(range=[-0.02, 1.02], scaleanchor="x", scaleratio=1, constrain="domain")
    return fig


def forest_fig(rows, x_title, zero=0.0, height=None):
    """rows: frame with label, est, lo, hi, primary (bool). Top row first."""
    rows = rows.iloc[::-1]
    fig = go.Figure()
    fig.add_vline(x=zero, line=dict(color=theme()["ref"], width=1))
    for primary, d in rows.groupby("primary"):
        c = theme()["series"][0] if primary else theme()["muted"]
        fig.add_trace(go.Scatter(
            x=d["est"], y=d["label"], mode="markers", showlegend=False,
            marker=dict(size=11 if primary else 8, color=c, symbol="diamond" if primary else "circle"),
            error_x=dict(type="data", symmetric=False, array=d["hi"] - d["est"],
                         arrayminus=d["est"] - d["lo"], thickness=1.2, width=3, color=c),
            customdata=np.c_[d["lo"], d["hi"]],
            hovertemplate="<b>%{y}</b><br>%{x:.4f} [%{customdata[0]:.4f}, %{customdata[1]:.4f}]<extra></extra>"))
    base_layout(fig, x_title, None, height=height or 90 + 34 * len(rows))
    fig.update_yaxes(categoryorder="array", categoryarray=list(rows["label"]))
    return fig


def dot_fig(frame, x_col, order, group_col, y_col, lo_col, hi_col, y_title, hover_fmt):
    """Categorical x with groups side by side; hollow markers where there is no CI."""
    fig = go.Figure()
    fig.add_hline(y=0, line=dict(color=theme()["ref"], width=1))
    groups = [g for g in SLOT if g in set(frame[group_col])]
    width = 0.6 / max(len(groups), 1)
    for i, g in enumerate(groups):
        d = frame[frame[group_col] == g].set_index(x_col).reindex(order).dropna(subset=[y_col])
        x = np.array([order.index(k) for k in d.index]) + (i - (len(groups) - 1) / 2) * width
        no_ci = d[lo_col].isna()
        fig.add_trace(go.Scatter(
            x=x, y=d[y_col], name=g, mode="markers",
            marker=dict(size=10, color=color(g),
                        symbol=[SYMBOL[g] + ("-open" if n else "") for n in no_ci]),
            error_y=dict(type="data", symmetric=False, thickness=1.2, width=3,
                         array=(d[hi_col] - d[y_col]).fillna(0),
                         arrayminus=(d[y_col] - d[lo_col]).fillna(0)),
            customdata=np.c_[d.index, d[lo_col], d[hi_col], d["n"]],
            hovertemplate=(f"<b>{g}</b>, %{{customdata[0]}}<br>{hover_fmt}"
                           "<br>%{customdata[3]:,} snapshots<extra></extra>")))
    base_layout(fig, None, y_title)
    fig.update_xaxes(tickvals=list(range(len(order))), ticktext=order)
    return fig


# ---------------------------------------------------------------- sidebar
with st.sidebar:
    st.markdown("### Polymarket Calibration")
    st.markdown(
        "Are Polymarket prices calibrated probabilities, and does calibration differ for "
        "crypto markets?\n\n"
        f"- [Code and README]({REPO})\n"
        f"- [Share this dashboard]({SITE})\n"
        f"- [Pre-registration]({REPO}/blob/main/docs/hypotheses.md) (2026-10-21)\n"
        f"- [Data profile]({REPO}/blob/main/docs/data_profile.md)")
    st.caption(
        "Every number on this page is read from CSVs committed in the repository, written "
        "by notebooks 01–03 and sql/04_dashboard. Data: SII-WANGZJ/Polymarket_data, trades "
        "through 2026-10-04.")

title_col, toggle_col = st.columns([5, 1], vertical_alignment="center")
title_col.title("Polymarket Calibration")
with toggle_col:
    theme_toggle(st.container(horizontal_alignment="right"))
tab_over, tab_rq1, tab_rq2, tab_rq3, tab_method = st.tabs(
    ["Overview", "RQ1 Crypto vs. non-crypto", "RQ2 Longshots", "RQ3 Smart money", "Method"])

# ---------------------------------------------------------------- overview
with tab_over:
    m = st.columns(4)
    m[0].metric("On-chain fills scanned", "1.27 B")
    m[1].metric("Resolved binary markets", "2,205,956")
    m[2].metric("Primary 1-day snapshots", "351,535")
    m[3].metric("Hypotheses pre-registered", "2026-10-21")

    st.markdown("""
#### Key findings

**RQ1. Crypto vs. non-crypto calibration: supported in 2 of 5 estimable cells, both fragile.**
One day out, crypto *event* markets are under-confident relative to non-crypto (slope 1.37
vs. 0.98). The gap shrinks to a non-significant +0.13 once early-closing markets are dropped,
and in deadline markets the early close is itself caused by the outcome. One hour out,
non-crypto *template* markets are under-confident (slope 1.30 vs. 1.10). That gap disappears
under 5-minute VWAP pricing.

**RQ2. Longshot bias: H2a supported, H2b not.** Longshots below 10¢ are overpriced by 0.25¢
on average, about 10% of their price. The bias sits in auto-generated ladders, mostly weather;
event-market longshots are calibrated. It does not shrink with liquidity.

**RQ3. Smart money: real but negligible.** Net buying by wallets with strong past records
predicts outcomes beyond the price (β = +0.038, p = 0.00006). But moving the signal from 0
to +1 shifts the win probability by only half a percentage point, and the information is in
heavy *selling* only.

Every departure from calibration that survives the pre-registered tests is confined to
particular market formats or price measures, and weakens or reverses under at least one
registered robustness check.
""")
    st.markdown("#### How calibrated is the whole market?")
    c1, c2 = st.columns([1, 2])
    with c1:
        h = st.radio("Horizon before resolution", list(HORIZONS), index=1, key="ov_h", horizontal=True)
    cal = load("calibration_by_subject", APP_DATA)
    allc = cal[cal["horizon"] == HORIZONS[h]].copy()
    allc["wins"] = allc["win_rate"] * allc["n"]
    allc["psum"] = allc["mean_price"] * allc["n"]
    pooled = allc.groupby(["format", "bin"], as_index=False)[["n", "wins", "psum"]].sum()
    pooled["mean_price"] = pooled["psum"] / pooled["n"]
    pooled["win_rate"] = pooled["wins"] / pooled["n"]
    pooled["lo"] = pooled["hi"] = pooled["win_rate"]   # no CI in the pooled view
    with c1:
        st.caption(
            "All primary snapshots at this horizon, pooled over subjects, split by format. "
            "*Event* markets are one-off questions; *template* markets are auto-generated "
            "series (crypto Up/Down, weather ladders). Points on the diagonal mean a price "
            "of p wins p of the time. No CIs in this pooled view; see the RQ tabs.")
    with c2:
        show(calibration_fig([(f, pooled[pooled["format"] == f]) for f in ["event", "template"]]),
             pooled[["format", "bin", "n", "mean_price", "win_rate"]].round(4))

# ---------------------------------------------------------------- RQ1
with tab_rq1:
    st.markdown(
        "**Test.** Within each horizon × format cell, does the calibration slope (logistic "
        "regression of the outcome on logit(price)) differ between crypto and non-crypto? "
        "Slope > 1: prices too timid. Slope < 1: prices overconfident. Holm-corrected, "
        "cluster-robust SEs.")
    c = st.columns([1, 1, 2])
    h = c[0].radio("Horizon", list(HORIZONS), index=1, key="rq1_h")
    f = c[1].radio("Format", ["event", "template"], key="rq1_f")
    view = c[2].radio("View", ["Crypto vs. non-crypto (registered)", "By subject (descriptive)"],
                      key="rq1_v")
    hz = HORIZONS[h]
    tests = load("rq1_tests")
    t = tests[(tests["horizon"] == hz) & (tests["format"] == f)].iloc[0]

    left, right = st.columns([3, 2])
    with left:
        if view.startswith("Crypto"):
            sym = st.checkbox("Symmetrize (use each market as both p and 1 − p)", key="rq1_sym")
            curves = load("rq1_curves_symmetrized" if sym else "rq1_curves")
            cell = curves[(curves["horizon"] == hz) & (curves["format"] == f)].rename(
                columns={"freq": "win_rate"})
            series = [(("crypto" if k else "non-crypto"), cell[cell["crypto"] == k])
                      for k in [False, True]]
            show(calibration_fig(series), cell.round(4))
            st.caption("Ten equal-width price bins; cluster-bootstrap 95% CIs (notebook 01). "
                       "Hollow markers: bins with fewer than 30 markets.")
        else:
            cal = load("calibration_by_subject", APP_DATA)
            cell = cal[(cal["horizon"] == hz) & (cal["format"] == f)].rename(
                columns={"ci_low": "lo", "ci_high": "hi"})
            present = [s for s in SUBJECTS if s in set(cell["subject"])]
            pick = st.multiselect("Subjects", present, default=present, key="rq1_subj")
            show(calibration_fig([(s, cell[cell["subject"] == s]) for s in pick]), cell)
            st.caption("Descriptive, not part of any test. Analytic CR1 cluster-robust 95% CIs "
                       "(sql/04_dashboard). Hollow markers: bins with fewer than 30 markets. "
                       "Cells with under 30 clusters (politics templates) have unreliable CIs.")
    with right:
        st.markdown(f"##### {h}, {f} markets")
        if not t["estimable"]:
            st.warning(
                "**Not estimable.** 97.6% of crypto prices in this cell are at or below 1¢ or at "
                "or above 99¢, so the logistic fit does not converge. This is a non-estimate, "
                "not a null, and the cell leaves the Holm family (D8 Part A).")
        else:
            k = st.columns(3)
            k[0].metric("Slope, non-crypto", f"{t['slope_noncrypto']:.3f}")
            k[1].metric("Slope, crypto", f"{t['slope_crypto']:.3f}")
            k[2].metric("Holm p", f"{t['p_holm']:.4f}",
                        "significant" if t["significant_holm"] else "not significant",
                        delta_color="normal" if t["significant_holm"] else "off", delta_arrow="off")
            st.markdown(f"Interaction (crypto − non-crypto): "
                        f"**{ci(t['interaction'], t['ci_low'], t['ci_high'])}**  \n"
                        f"{t['n_crypto']:,} crypto / {t['n_noncrypto']:,} non-crypto markets")
            sens = load("rq1_sensitivities")
            s = sens[(sens["horizon"] == hz) & (sens["format"] == f) & sens["estimable"]]
            rows = pd.concat([
                pd.DataFrame([{"label": "registered estimate", "est": t["interaction"],
                               "lo": t["ci_low"], "hi": t["ci_high"], "primary": True}]),
                pd.DataFrame({"label": s["sensitivity"], "est": s["interaction"],
                              "lo": s["ci_low"], "hi": s["ci_high"], "primary": False})])
            st.markdown("**Robustness checks** (interaction, 95% CI)")
            show(forest_fig(rows, "slope interaction"), rows.drop(columns="primary").round(4))

    st.markdown("##### Scores by subject")
    desc = load("rq1_descriptives")
    d = desc[(desc["horizon"] == hz) & (desc["format"] == f)]
    st.dataframe(pd.DataFrame({
        "subject": d["subject"], "markets": d["n"], "clusters": d["clusters"],
        "Brier [95% CI]": [ci(*r, digits=4) for r in d[["brier", "brier_lo", "brier_hi"]].values],
        "log loss [95% CI]": [ci(*r, digits=4) for r in d[["log_loss", "ll_lo", "ll_hi"]].values],
        "calibration-in-the-large [95% CI]": [ci(*r) for r in d[["citl", "citl_lo", "citl_hi"]].values],
    }), hide_index=True, width="stretch")
    st.caption("Brier and log loss: lower is better; they mix calibration with how decisive "
               "prices are, so compare within a horizon. CITL: positive means token1 wins more "
               "often than priced; its sign is arbitrary for about two-thirds of markets.")

# ---------------------------------------------------------------- RQ2
with tab_rq2:
    st.markdown(
        "**Test.** Are longshots (the cheaper side, priced below 10¢, one day out) overpriced "
        "(H2a), and does the bias shrink in more liquid markets (H2b)?")
    tests = load("rq2_tests").set_index("test")
    k = st.columns(4)
    k[0].metric("H2a mean (won − price)", f"{tests.loc['H2a', 'estimate'] * 100:+.2f}¢")
    k[1].metric("H2a Holm p", f"{tests.loc['H2a', 'p_holm']:.5f}", "supported", delta_arrow="off")
    k[2].metric("H2b liquidity slope", f"{tests.loc['H2b', 'estimate']:+.5f}")
    k[3].metric("H2b Holm p", f"{tests.loc['H2b', 'p_holm']:.3f}", "not supported",
                delta_color="off", delta_arrow="off")

    st.markdown("##### Where the bias sits: price bands (exploratory)")
    c = st.columns([1, 1, 2])
    split = c[0].radio("Split by", ["format", "subject"], key="rq2_split")
    measure = c[1].radio("Measure", ["% of price", "cents"], key="rq2_m")
    bands = load("rq2_price_bands" if split == "format" else "rq2_price_bands_subject")
    order = ["0.1c", "0.2-0.5c", "0.6-2c", "2.1-5c", "5.1-10c"]
    if measure == "cents":
        bands = bands.assign(y=bands["bias"] * 100, lo=bands["ci_low"] * 100, hi=bands["ci_high"] * 100)
        yt, hf = "mean (won − price), ¢", "%{y:+.3f}¢ [%{customdata[1]:.3f}, %{customdata[2]:.3f}]"
    else:
        bands = bands.assign(y=bands["relative_bias"] * 100,
                             lo=bands["ci_low"] / bands["mean_price"] * 100,
                             hi=bands["ci_high"] / bands["mean_price"] * 100)
        yt, hf = "bias, % of price", "%{y:+.1f}% [%{customdata[1]:.1f}, %{customdata[2]:.1f}]"
    show(dot_fig(bands, "band", order, split, "y", "lo", "hi", yt, hf),
         bands.drop(columns=["y", "lo", "hi"]).round(5))
    st.caption("Negative = overpriced. CR1 cluster-robust 95% CIs. Hollow markers: no wins in the "
               "cell, so no CI. Cells with under 30 clusters are omitted. Event longshots are "
               "calibrated above the 0.1¢ tick; template ladders, mostly weather, are not.")

    left, right = st.columns(2)
    with left:
        st.markdown("##### By liquidity quintile (H2b)")
        q = load("rq2_liquidity_quintiles")
        q = q.assign(label=[f"Q{i} (median ${m:,.0f})" for i, m in zip(q["liq_quintile"], q["median_liq_usd"])],
                     est=q["mean_resid"] * 100, lo=q["lo"] * 100, hi=q["hi"] * 100, primary=True)
        show(forest_fig(q, "mean (won − price), ¢"), q[["label", "n", "clusters", "est", "lo", "hi"]].round(4))
        st.caption("Not monotone: the thinnest quintile shows no bias, so the bias does not shrink "
                   "with liquidity.")
    with right:
        st.markdown("##### Robustness checks (H2a)")
        sens = load("rq2_sensitivities")
        s = sens[(sens["test"] == "H2a") & sens["fitted"]]
        rows = pd.concat([
            pd.DataFrame([{"label": "registered estimate", "est": tests.loc["H2a", "estimate"] * 100,
                           "lo": tests.loc["H2a", "ci_low"] * 100, "hi": tests.loc["H2a", "ci_high"] * 100,
                           "primary": True}]),
            pd.DataFrame({"label": s["sensitivity"], "est": s["estimate"] * 100,
                          "lo": s["ci_low"] * 100, "hi": s["ci_high"] * 100, "primary": False})])
        show(forest_fig(rows, "mean (won − price), ¢"), rows.drop(columns="primary").round(4))
        st.caption("A $10,000 volume floor (5.2) flips the sign; 5-minute VWAP pricing (5.3) "
                   "covers 0. The 2023 estimate rests on 317 snapshots.")

# ---------------------------------------------------------------- RQ3
with tab_rq3:
    st.markdown(
        "**Test.** Does net buying by wallets with strong *prior* track records (computed only "
        "from markets already resolved at the time) predict outcomes beyond the price? "
        "Model: outcome ~ logit(price) + signal, 1-day snapshots. The signal runs from −1 "
        "(smart wallets all selling) to +1 (all buying).")
    tests = load("rq3_tests")
    conf = tests.iloc[0]
    k = st.columns(4)
    k[0].metric("Signal coefficient", f"{conf['coef']:+.3f}",
                f"95% CI {conf['ci_low']:.3f} to {conf['ci_high']:.3f}", delta_color="off",
                delta_arrow="off")
    k[1].metric("p-value", f"{conf['p_value']:.5f}", "supported", delta_arrow="off")
    k[2].metric("Signal 0 → +1", f"+{conf['ame_0_to_1'] * 100:.2f} pp", "win probability",
                delta_color="off", delta_arrow="off")
    k[3].metric("Markets", f"{conf['n']:,}", f"{conf['clusters']:,} clusters", delta_color="off",
                delta_arrow="off")

    left, right = st.columns(2)
    with left:
        st.markdown("##### Outcome vs. price by signal bin (descriptive)")
        b = load("rq3_signal_bins")
        b = b.assign(label=[f"{s} · {n:,}" for s, n in zip(b["signal_bin"], b["markets"])],
                     est=b["resid"] * 100, lo=b["ci_low"] * 100, hi=b["ci_high"] * 100, primary=True)
        show(forest_fig(b, "mean (won − price), ¢"), b[["signal_bin", "markets", "clusters", "est", "lo", "hi"]].round(4))
        st.caption("Heavy smart selling marks markets that win less often than priced (−0.93¢). "
                   "Heavy smart buying, the largest bin, carries nothing. The effect is one-sided.")
    with right:
        st.markdown("##### Secondary tests, refits and robustness checks")
        refits = load("rq3_refits")
        sens = load("rq3_sensitivities")
        rows = pd.concat([
            pd.DataFrame({"label": tests["test"], "est": tests["coef"], "lo": tests["ci_low"],
                          "hi": tests["ci_high"], "primary": [True] + [False] * (len(tests) - 1)}),
            pd.DataFrame({"label": refits["refit"], "est": refits["coef"], "lo": refits["ci_low"],
                          "hi": refits["ci_high"], "primary": False}),
            pd.DataFrame({"label": sens["sensitivity"], "est": sens["coef"], "lo": sens["ci_low"],
                          "hi": sens["ci_high"], "primary": False})])
        chart_rows = rows[~rows["label"].str.contains("2023")]
        show(forest_fig(chart_rows, "signal coefficient"), rows.drop(columns="primary").round(4))
        st.caption("Stable across refits, but the CI covers 0 with at least $1,000 of smart volume "
                   "(A4) and under VWAP pricing (5.3). 2023 (577 markets, CI ±0.5) is omitted "
                   "from the chart for scale; it is in the data table.")

# ---------------------------------------------------------------- method
with tab_method:
    st.markdown(f"""
#### Design

- **Unit of analysis:** the market. Each resolved binary market contributes one price per
  horizon (1 week, 1 day, 1 hour before resolution): the last trade of at least $1 before
  that point, found with window functions over 1.08 B trades.
- **Primary population:** snapshots within a staleness cap, in markets with at least $1,000
  of volume.
- **Resolution time:** Gamma API `closedTime`, checked against on-chain resolution events for
  470 markets (payouts agree in every one).
- **Categories:** no usable category field exists, so a rule-based classifier assigns subject
  (crypto, sports, politics, weather, other) and format (event, template). It was frozen
  before validation against 400 hand-labeled markets: crypto precision 1.000, recall 0.994.
- **Inference:** cluster-robust standard errors (clusters = event or template series);
  Holm correction across the RQ1 cells and across the two RQ2 tests. RQ3 has one
  confirmatory test.

#### Pre-registration

The hypotheses, tests and robustness checks were committed on 2026-10-21, before any price
was compared with any outcome. Later estimation choices were logged as dated deviations
(D1–D9) before the results they affect existed, with one exception (D8 Part A), which is
marked as such. Each confirmatory notebook runs a planted control on simulated outcomes
before reading the real ones.

#### Stack

DuckDB over Hugging Face Parquet (45.8 GB of trades, queried in place), numbered SQL files
for staging, intermediate and mart layers, statsmodels for estimation, Streamlit and Plotly
for this page. Source: [{REPO.removeprefix('https://')}]({REPO}).
""")
