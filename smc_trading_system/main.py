import MetaTrader5 as mt5
import os
import schedule
import time

from config import SYMBOLS, TIMEFRAMES, SCAN_THRESHOLD
from scanner import get_data, score_setup
from screenshot_engine import take_screenshots
from chart_analysis import analyze_chart
from config import SCREENSHOT_FOLDER

def init_mt5():

    if not mt5.initialize():

        print("MT5 connection failed")

        quit()

    print("MT5 connected")


def run_system():

    print("\nRunning Market Scan")

    for symbol in SYMBOLS:

        df = get_data(symbol, list(TIMEFRAMES.values())[2])

        score = score_setup(df)

        print(symbol, "score:", score)

        if score >= SCAN_THRESHOLD:

            print("Setup detected:", symbol)

            take_screenshots(symbol)

            for tf in ["h4","h1","m15"]:

                filename = f"{SCREENSHOT_FOLDER}/{symbol.lower()}_{tf}.png"

                if os.path.exists(filename):

                    analyze_chart(filename)


def main():

    init_mt5()

    run_system()

    schedule.every(5).minutes.do(run_system)

    while True:

        schedule.run_pending()

        time.sleep(1)


if __name__ == "__main__":

    main()
