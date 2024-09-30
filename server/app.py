from collections import defaultdict

from flask import Flask, jsonify
from nyct_gtfs import NYCTFeed

app = Flask(__name__)

API_KEY = "" # REDACTED: NYC transit API key

ALL_STOPS = [] # REDACTED: A list of ("line", "stop_id") pairs


def get_times_for_line(line, stop_id):
    feed = NYCTFeed(line, api_key=API_KEY)
    trains = feed.filter_trips(line_id=line)
    results = defaultdict(list)
    for train in trains:
        for update in train.stop_time_updates:
            if stop_id in update.stop_id:
                if "N" in update.stop_id:
                    results["uptown"].append(update.departure.isoformat())
                elif "S" in update.stop_id:
                    results["downtown"].append(update.departure.isoformat())
    return results


@app.route("/subway")
def subway():
    results = defaultdict(dict)
    for line_stop in ALL_STOPS:
        results[line_stop[1]][line_stop[0]] = get_times_for_line(
            line_stop[0], line_stop[1]
        )
    print(results)
    resp = jsonify(results)
    resp.status_code = 200
    return resp


def main():
    app.run()


if __name__ == "__main__":
    main()
