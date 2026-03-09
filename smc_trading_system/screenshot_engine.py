import MetaTrader5 as mt5
import os
from config import TIMEFRAMES, SCREENSHOT_FOLDER

def take_screenshots(symbol):

    for tf_name, tf in TIMEFRAMES.items():

        chart_id = mt5.chart_open(symbol, tf)

        if chart_id == 0:
            continue

        filename = f"{SCREENSHOT_FOLDER}/{symbol.lower()}_{tf_name.lower()}.png"

        mt5.chart_screen_shot(chart_id, filename, 1280, 720)

        print("Saved:", filename)
