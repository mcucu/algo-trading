from PythonMetaTrader5 import MetaTrader5
import pandas as pd
import numpy as np
import time
import logging
from datetime import datetime

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s [%(levelname)s] %(message)s")

# ---- CONNECT ----
mt5 = MetaTrader5()

try:
    mt5.initialize()
except Exception as e:
    logging.error("Gagal inisialisasi koneksi PythonMetaTrader5.")
    raise e

# ------------------------------------
# PARAMETERS
# ------------------------------------
SYMBOLS = ["EURUSD", "XAUUSD"]
TIMEFRAME = "M30"

LOOKBACK = 200
MA_SHORT = 20
MA_LONG = 50
RSI_PERIOD = 14

RSI_OVERBOUGHT = 70
RSI_OVERSOLD = 30

LOT = 0.01
SL_PIPS = 200
TP_PIPS = 400
SLEEP = 60

# ------------------------------------
# INDICATORS
# ------------------------------------
def sma(series, period):
    return series.rolling(period).mean()

def rsi(series, period=14):
    delta = series.diff()
    gain = delta.clip(lower=0)
    loss = (-delta).clip(lower=0)
    avg_gain = gain.ewm(alpha=1/period, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1/period, adjust=False).mean()
    rs = avg_gain / avg_loss
    return 100 - (100/(1+rs))

# ------------------------------------
# SIGNAL GENERATOR
# ------------------------------------
def compute_signal(df):
    close = df["close"]

    ma_s = sma(close, MA_SHORT)
    ma_l = sma(close, MA_LONG)
    r = rsi(close, RSI_PERIOD)

    prev_s = ma_s.iloc[-2]
    prev_l = ma_l.iloc[-2]
    last_s = ma_s.iloc[-1]
    last_l = ma_l.iloc[-1]
    last_rsi = r.iloc[-1]

    bullish = (prev_s <= prev_l) and (last_s > last_l)
    bearish = (prev_s >= prev_l) and (last_s < last_l)

    if bullish and last_rsi < RSI_OVERBOUGHT:
        return "buy"

    if bearish and last_rsi > RSI_OVERSOLD:
        return "sell"

    return None

# ------------------------------------
# BOT LOOP
# ------------------------------------
def run_bot():
    logging.info("Bot mulai berjalan...")

    while True:
        for symbol in SYMBOLS:
            try:
                df = mt5.get_rates(symbol, TIMEFRAME, LOOKBACK)

                if df is None or len(df) == 0:
                    logging.warning(f"Tidak ada data {symbol}")
                    continue

                df = pd.DataFrame(df)
                signal = compute_signal(df)

                logging.info(f"{symbol} → signal: {signal}")

                if signal == "buy":
                    mt5.buy(symbol, LOT, sl=SL_PIPS, tp=TP_PIPS)

                elif signal == "sell":
                    mt5.sell(symbol, LOT, sl=SL_PIPS, tp=TP_PIPS)

            except Exception as e:
                logging.exception(f"Error processing {symbol}: {e}")

        logging.info(f"Sleep {SLEEP}s...")
        time.sleep(SLEEP)

try:
    run_bot()
except KeyboardInterrupt:
    logging.info("Bot dihentikan.")
finally:
    mt5.shutdown()
