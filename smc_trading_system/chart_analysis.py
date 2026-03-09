import cv2
import numpy as np
import os
from config import SCREENSHOT_FOLDER, ANNOTATED_FOLDER

def analyze_chart(filename):

    img = cv2.imread(filename)

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

    edges = cv2.Canny(gray, 50, 150)

    lines = cv2.HoughLinesP(
        edges,
        1,
        np.pi/180,
        threshold=100,
        minLineLength=200,
        maxLineGap=10
    )

    if lines is not None:

        for line in lines:

            x1, y1, x2, y2 = line[0]

            if abs(y1 - y2) < 5:

                cv2.line(
                    img,
                    (x1, y1),
                    (x2, y2),
                    (0, 0, 255),
                    2
                )

    name = os.path.basename(filename)

    out = f"{ANNOTATED_FOLDER}/{name}"

    cv2.imwrite(out, img)

    print("Annotated:", out)
