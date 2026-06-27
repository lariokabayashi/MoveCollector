"""
Visualiza os pontos GPS de um mapa Folium (all_day_maps.html).

Extrai lat/lon, cor e horário de cada circleMarker e plota o trajeto.
Salva em PDF e PNG.

Uso:
    python visualize_all_day_maps.py [arquivo.html]
"""

import re
import sys
import os
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import datetime

# ----- parsing -----
def parse_markers(html_path):
    html = open(html_path, encoding="utf-8").read()
    pat = re.compile(
        r'L\.circleMarker\(\s*\[(-?\d+\.\d+),\s*(-?\d+\.\d+)\],\s*'
        r'\{[^}]*?"color":\s*"([^"]+)"[^}]*?\}\s*\)'
        r'.*?bindTooltip\(\s*`<div>\s*([0-9:]+)',
        re.DOTALL,
    )
    lats, lons, colors, times = [], [], [], []
    for lat, lon, color, t in pat.findall(html):
        lats.append(float(lat))
        lons.append(float(lon))
        colors.append(color)
        times.append(datetime.strptime(t, "%H:%M:%S"))
    return lats, lons, colors, times


def main(html_path):
    lats, lons, colors, times = parse_markers(html_path)
    print(f"Pontos extraídos: {len(lats)}")
    print(f"Período: {times[0].time()} → {times[-1].time()}")

    base = os.path.splitext(os.path.basename(html_path))[0]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 7))

    # --- Mapa 1: cores originais do Folium ---
    ax1.scatter(lons, lats, c=colors, s=12, edgecolors="none", alpha=0.8)
    ax1.set_title("Trajeto — cores originais")
    ax1.set_xlabel("Longitude")
    ax1.set_ylabel("Latitude")
    ax1.set_aspect("equal", adjustable="datalim")
    ax1.grid(True, alpha=0.3)

    # --- Mapa 2: colorido pela ordem temporal ---
    t_num = mdates.date2num(times)
    sc = ax2.scatter(lons, lats, c=t_num, cmap="viridis", s=12,
                     edgecolors="none", alpha=0.8)
    ax2.set_title("Trajeto — progressão no tempo")
    ax2.set_xlabel("Longitude")
    ax2.set_ylabel("Latitude")
    ax2.set_aspect("equal", adjustable="datalim")
    ax2.grid(True, alpha=0.3)

    cbar = fig.colorbar(sc, ax=ax2, fraction=0.046, pad=0.04)
    cbar.ax.yaxis.set_major_locator(mdates.AutoDateLocator())
    cbar.ax.yaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
    cbar.set_label("Horário")

    fig.suptitle(f"Visualização GPS — {base} ({len(lats)} pontos)", fontsize=14)
    fig.tight_layout()

    pdf = f"{base}_view.pdf"
    png = f"{base}_view.png"
    fig.savefig(pdf, bbox_inches="tight")
    fig.savefig(png, dpi=150, bbox_inches="tight")
    print(f"Salvo: {pdf}")
    print(f"Salvo: {png}")
    plt.show()


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "all_day_maps.html"
    main(path)
