import MetaTrader5 as mt5
import pandas as pd

def get_data(symbol, timeframe, bars=120):

    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, bars)

    df = pd.DataFrame(rates)

    return df


def detect_displacement(df):

    body = abs(df['close'] - df['open'])
    avg = body.mean()

    if body.iloc[-1] > avg * 2:
        return True

    return False


def detect_fvg(df):

    c1 = df.iloc[-3]
    c3 = df.iloc[-1]

    if c1.high < c3.low:
        return "bullish"

    if c1.low > c3.high:
        return "bearish"

    return None


def score_setup(df):

    score = 0

    if detect_displacement(df):
        score += 2

    if detect_fvg(df):
        score += 2

    return score
