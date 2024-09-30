import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:graphic/graphic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:googleapis/calendar/v3.dart' as calendar;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:weather/weather.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:weather_icons/weather_icons.dart';

void main() {
  runApp(const MyApp());
}

final knownStops = {}; // REDACTED

final calendars = []; // REDACTED

final tickers = ['SPY', 'GOOG', 'AAPL'];

const stockGreen = Colors.green;
const stockRed = Colors.red;

const oauthClientId = ''; // REDACTED

const scopes = ['email', calendar.CalendarApi.calendarReadonlyScope];

GoogleSignIn _googleSignIn = GoogleSignIn(
  clientId: oauthClientId,
  scopes: scopes,
);

GoogleSignInAccount? user;

List<Stock>? fetchedStocks;

extension IterableExtensions<T> on Iterable<T> {
  Iterable<R> mapIndexedWithLength<R>(
      R Function(int index, T value, int length) callback) {
    int length = this.length;
    return mapIndexed((index, value) => callback(index, value, length));
  }

  Iterable<T> expandIndexedWithLength(
      Iterable<T> Function(int index, T value, int length) callback) {
    int length = this.length;
    return expandIndexed((index, value) => callback(index, value, length));
  }
}

class Stock {
  final String ticker;
  final double prevClose;
  final double current;
  final List<double> chartData;

  Stock(this.ticker, this.prevClose, this.current, this.chartData);

  factory Stock.fromJson(Map<String, dynamic> json) {
    final data = json['chart']['result'][0];
    final meta = data['meta'];
    final ticker = meta['symbol'] as String;
    final prevClose = meta['chartPreviousClose'] as double;

    final current = meta['regularMarketPrice'] as double;

    final chartData = (data['indicators']['quote'][0]['close'] as List<dynamic>)
        .whereNotNull()
        .map((e) => e as double)
        .toList();

    return Stock(ticker, prevClose, current, chartData.toList());
  }

  static Future<Stock> fromTicker(String ticker) async {
    final json = await http
        .get(Uri.parse(
            'https://query2.finance.yahoo.com/v8/finance/chart/$ticker'))
        .then((response) => jsonDecode(response.body));
    return Stock.fromJson(json);
  }
}

extension ColorSchemeExtension on BuildContext {
  ColorScheme get colorScheme {
    return Theme.of(this).colorScheme;
  }
}

class Stop {
  final String stopId;
  final String stopName;
  int? walkingTime;
  int? sorting;
  List<StopLine> lines;

  Stop(this.stopId, this.stopName, this.lines,
      {this.walkingTime, this.sorting});

  factory Stop.fromJson(String stopId, Map<String, dynamic> json) {
    final List<StopLine> lines = [];
    json.forEach((key, value) {
      lines.add(StopLine.fromJson(key, value));
    });

    return Stop(stopId, knownStops[stopId]?.stopName ?? '', lines);
  }
}

enum Direction { uptown, downtown }

class Train {
  final String stopId;
  final String stopName;
  final String lineName;
  final DateTime time;
  final Direction direction;

  Train(this.stopId, this.stopName, this.lineName, this.time, this.direction);
}

class StopLine {
  final String lineName;

  List<DateTime> uptownTrains;
  List<DateTime> downtownTrains;

  StopLine(this.lineName, this.uptownTrains, this.downtownTrains);

  static List<DateTime> trainsFromJson(Map<String, dynamic> json, String key) {
    final value = (json[key] ?? []) as List<dynamic>;
    return value.map((e) => e as String).map((e) => DateTime.parse(e)).toList();
  }

  factory StopLine.fromJson(String lineName, Map<String, dynamic> json) {
    return StopLine(lineName, trainsFromJson(json, 'uptown'),
        trainsFromJson(json, 'downtown'));
  }

  Widget departures(
      List<DateTime> trains, String prefix, BuildContext context) {
    final now = DateTime.now();
    trains.sort();
    final departures = trains
        .map((e) => e.difference(now).inMinutes)
        .where((element) => element > 0 && element < 30)
        .take(3)
        .toList();

    return Row(
      children: [
        SizedBox(
            width: 135,
            child: RichText(
              text: TextSpan(
                  text: '$prefix ',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w300,
                      color: context.colorScheme.onSurfaceVariant)),
            )),
        RichText(
            text: TextSpan(
                style: TextStyle(
                    fontSize: 24, color: context.colorScheme.onSurfaceVariant),
                children: <TextSpan>[
              ...departures.expandIndexed((index, departure) => [
                    TextSpan(
                        text: departure.toString(),
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: context.colorScheme.onSurfaceVariant)),
                    TextSpan(
                        text: ' min',
                        style: TextStyle(
                            color: context.colorScheme.onSurfaceVariant)),
                    if (index != departures.length - 1)
                      TextSpan(
                          text: ', ',
                          style: TextStyle(
                              color: context.colorScheme.onSurfaceVariant))
                  ])
            ]))
      ],
    );
  }

  Widget? build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Image(
              width: 36,
              height: 36,
              image:
                  AssetImage('assets/mta_icons/${lineName.toLowerCase()}.png')),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            departures(uptownTrains, 'Uptown', context),
            departures(downtownTrains, 'Downtown', context)
          ])
        ])
      ],
    );
  }
}

Future<List<calendar.Event>> fetchCalendarEvents() async {
  user ??= await _googleSignIn.signInSilently();

  if (user == null) return [];

  final client = await _googleSignIn.authenticatedClient();
  final calendarApi = calendar.CalendarApi(client!);

  final List<Future<calendar.Events>> eventsFutures = [];

  for (final calendarId in calendars) {
    eventsFutures.add(calendarApi.events
        .list(calendarId, timeMin: DateTime.now(), singleEvents: true));
  }

  final allEvents = await Future.wait(eventsFutures);

  final concatEvents =
      allEvents.map((e) => e.items ?? []).expand((e) => e).toList();
  return concatEvents;
}

Future<List<dynamic>> getData() async {
  final wf = WeatherFactory(''); // REDACTED

  const lat = 40.7221;
  const long = -73.9967;
  final weatherResponse = wf.currentWeatherByLocation(lat, long);
  final stopsResponse = http.get(Uri.parse('')); // REDACTED

  final forecastResponse = wf.fiveDayForecastByLocation(lat, long);

  Future<List<Stock>>? stocksResponse;

  if (fetchedStocks == null ||
      (DateTime.now().hour > 8 && DateTime.now().hour < 17)) {
    final stocks = tickers.map((ticker) => Stock.fromTicker(ticker));
    stocksResponse = Future.wait(stocks);
  } else {
    stocksResponse = Future.value(fetchedStocks);
  }

  final eventsResponse = fetchCalendarEvents();

  final responses = await Future.wait([
    weatherResponse,
    stopsResponse,
    forecastResponse,
    stocksResponse,
    eventsResponse
  ]);

  final weatherData = responses[0] as Weather;
  final stopsData = responses[1] as http.Response;
  final forecastData = responses[2] as List<Weather>;
  final stockData = responses[3] as List<Stock>;
  final eventsData = responses[4] as List<calendar.Event>;

  fetchedStocks = stockData;

  final data = jsonDecode(stopsData.body);
  final List<Stop> stops = [];
  data.forEach((key, value) {
    stops.add(Stop.fromJson(key, value));
  });
  return [
    stops,
    [weatherData, ...forecastData],
    stockData,
    eventsData
  ];
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedColor = Color.fromARGB(255, 56, 122, 83);

    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seedColor),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: seedColor, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  Future<List<dynamic>> _data = getData();
  DateTime lastUpdated = DateTime.now();

  @override
  initState() {
    super.initState();
    Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {});
    });

    Timer.periodic(const Duration(seconds: 61), (timer) async {
      final newData = await getData();
      _data = Future.value(newData);
      lastUpdated = DateTime.now();
    });
  }

  List<Widget> timeLayoutTrains(
      Map<String, Iterable<Train>> stops, Direction direction) {
    return stops.entries
        .sorted((stopA, stopB) => (knownStops[stopA.key]?.sorting ?? 0)
            .compareTo(knownStops[stopB.key]?.sorting ?? 0))
        .map<List<Widget>>((entry) {
          final Iterable<Train> trains =
              entry.value.where((train) => train.direction == direction);

          final lineOptions = trains.map((train) => train.lineName).toSet();

          final activeDirectionLineNumber = lineOptions.length;
          var otherDirectionLineNumber = entry.value
              .where((train) => train.direction != direction)
              .map((train) => train.lineName)
              .toSet()
              .length;

          final lines = <String, Iterable<Train>>{
            for (final lineName in lineOptions)
              lineName: trains.where((train) => train.lineName == lineName)
          };

          final stop = knownStops[entry.key]!;

          return [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              RichText(
                text: TextSpan(
                    text: stop.stopName,
                    style: TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w300,
                        color: context.colorScheme.onSurfaceVariant)),
              ),
              Row(children: [
                Icon(Icons.directions_walk,
                    color: context.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Column(children: [
                  const SizedBox(height: 3),
                  RichText(
                    text: TextSpan(
                        text: '${stop.walkingTime} min',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w300,
                            color: context.colorScheme.onSurfaceVariant)),
                  )
                ])
              ]),
              const SizedBox(height: 6),
            ]),
            ...lines.entries.map((lineEntry) => Row(children: [
                  Image(
                      width: 22,
                      height: 22,
                      image: AssetImage(
                          'assets/mta_icons/${lineEntry.key.toLowerCase()}.png')),
                  const SizedBox(width: 10),
                  ...lineEntry.value
                      .where((train) =>
                          train.time.difference(DateTime.now()).inMinutes <= 60)
                      .take(3)
                      .whereIndexed((index, train) =>
                          index <= 1 ||
                          train.time.difference(DateTime.now()).inMinutes <= 30)
                      .mapIndexedWithLength((index, train, length) => RichText(
                              text: TextSpan(
                                  style: TextStyle(
                                      fontSize: 24,
                                      color:
                                          context.colorScheme.onSurfaceVariant),
                                  children: <TextSpan>[
                                TextSpan(
                                    text: train.time
                                        .difference(DateTime.now())
                                        .inMinutes
                                        .toString(),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    )),
                                const TextSpan(text: ' min'),
                                if (index < length - 1)
                                  const TextSpan(text: ', '),
                              ])))
                ])),
            ...Iterable.generate(max(
                    0, otherDirectionLineNumber - activeDirectionLineNumber))
                .map((_) => RichText(
                    text: const TextSpan(
                        style: TextStyle(fontSize: 24),
                        children: <TextSpan>[TextSpan(text: ' ')])))
          ];
        })
        .expandIndexedWithLength((index, value, length) => [
              value,
              if (index < length - 1) [const SizedBox(height: 24)]
            ])
        .expand((element) => element)
        .toList();
  }

  Widget timeLayout(List<Stop> data) {
    final allTrains = data
        .expand((stop) => stop.lines.expand((stopLine) => [
              ...stopLine.downtownTrains.map((downtownStop) => Train(
                  stop.stopId,
                  stop.stopName,
                  stopLine.lineName,
                  downtownStop,
                  Direction.downtown)),
              ...stopLine.uptownTrains.map((uptownStop) => Train(
                  stop.stopId,
                  stop.stopName,
                  stopLine.lineName,
                  uptownStop,
                  Direction.uptown))
            ]))
        .sortedBy((train) => train.time)
        .where((train) {
      final difference = train.time.difference(DateTime.now()).inMinutes;
      final reachable =
          difference >= (knownStops[train.stopId]?.walkingTime ?? 0);
      final soon = difference <= 60;
      return reachable && soon;
    }).toList();

    final stops = <String, Iterable<Train>>{
      for (final stopId in knownStops.keys)
        stopId: allTrains.where((train) => train.stopId == stopId)
    };

    return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        RichText(
          text: TextSpan(
              text: 'Downtown',
              style: TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.w400,
                  color: context.colorScheme.onSurfaceVariant)),
        ),
        const SizedBox(height: 16),
        ...timeLayoutTrains(stops, Direction.downtown)
      ]),
      const SizedBox(width: 35),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        RichText(
          text: TextSpan(
              text: 'Uptown',
              style: TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.w400,
                  color: context.colorScheme.onSurfaceVariant)),
        ),
        const SizedBox(height: 16),
        ...timeLayoutTrains(stops, Direction.uptown)
      ]),
    ]);
  }

  Widget traditionalLayout(List<Stop> data) {
    return Padding(
        padding: const EdgeInsets.all(16),
        child: IntrinsicWidth(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: data
              .map<Widget>((e) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          TextSpan(text: e.stopName),
                          style: const TextStyle(
                              fontSize: 48, fontWeight: FontWeight.w300),
                        ),
                        ...e.lines
                            .map((e) => e.build(context))
                            .whereType<Widget>()
                            .expandIndexedWithLength((index, element, length) =>
                                [
                                  element,
                                  if (index < length - 1)
                                    const Divider(
                                        color: Colors.grey, thickness: 2)
                                ])
                      ]))
              .expandIndexedWithLength((index, element, length) => [
                    element,
                    if (index < length - 1)
                      const SizedBox(
                        height: 5,
                      )
                  ])
              .toList(),
        )));
  }

  IconData getWeatherIconData(String iconString) {
    switch (iconString) {
      case "01d":
        return WeatherIcons.day_sunny;
      case "01n":
        return WeatherIcons.night_clear;
      case "02d":
        return WeatherIcons.day_cloudy;
      case "02n":
        return WeatherIcons.night_cloudy;
      case "03d":
      case "04d":
        return WeatherIcons.cloudy;
      case "03n":
      case "04n":
        return WeatherIcons.night_cloudy;
      case "09d":
      case "10d":
        return WeatherIcons.rain;
      case "09n":
      case "10n":
        return WeatherIcons.rain;
      case "11d":
      case "11n":
        return WeatherIcons.thunderstorm;
      case "13d":
      case "13n":
        return WeatherIcons.snow;
      case "50d":
      case "50n":
        return WeatherIcons.fog;
      default:
        return WeatherIcons.na;
    }
  }

  TableRow forecastWidget(Weather weather) {
    final currentTemp = (weather.temperature?.fahrenheit ?? 0).round();
    final currentDate = weather.date ?? DateTime.now();
    final currentPop = ((weather.precipitation ?? 0) * 100).round();

    return TableRow(children: [
      Align(
          alignment: Alignment.centerRight,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text.rich(
              TextSpan(text: DateFormat('h').format(currentDate)),
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  height: 1.05,
                  color: context.colorScheme.onSecondaryContainer),
            ),
            Text.rich(
              TextSpan(text: DateFormat('a').format(currentDate)),
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w300,
                  height: 1.05,
                  color: context.colorScheme.onSecondaryContainer),
            ),
          ])),
      const SizedBox(width: 20),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Icon(getWeatherIconData(weather.weatherIcon ?? ''),
            size: 32, color: context.colorScheme.onSecondaryContainer),
      ),
      const SizedBox(width: 25),
      Text.rich(TextSpan(text: '$currentTemp°'),
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              height: 1.1,
              color: context.colorScheme.onSecondaryContainer)),
      const SizedBox(width: 15),
      Text.rich(TextSpan(text: '$currentPop%'),
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w400,
              height: 1.1,
              color: context.colorScheme.onSecondaryContainer)),
    ]);
  }

  bool showStocks() {
    return true;
    //final hour = DateTime.now().hour;
    //return isWeekday && (hour == 9 || (hour >= 17 && hour <= 19));
  }

  double mergePrecipChance(Iterable<double> chances) {
    return 1 -
        chances.map((e) => (1 - e)).reduce((value, element) => value * element);
  }

  List<Widget> weatherWidget(List<Weather> weatherList) {
    final weather = weatherList.first;

    final currentTemp = (weather.temperature?.fahrenheit ?? 0).round();
    final highTemp = weatherList
        .where((value) => (value.date?.day ?? -1) == DateTime.now().day)
        .map((e) => e.tempMax?.fahrenheit ?? 0)
        .reduce(max)
        .round();
    final lowTemp = weatherList
        .where((value) =>
            (value.date ?? DateTime.now()).difference(DateTime.now()).inHours <
            24)
        .map((e) => e.tempMin?.fahrenheit ?? 0)
        .reduce(min)
        .round();

    final feelsLike = (weather.tempFeelsLike?.fahrenheit ?? 0).round();

    final weatherIconData = getWeatherIconData(weather.weatherIcon ?? '');

    final useTomorrowPrecip = DateTime.now().hour >= 20; // After 8 PM.
    final precipList = weatherList
        .where((weather) =>
            (weather.date?.day ?? -1) ==
            DateTime.now()
                .add(useTomorrowPrecip
                    ? const Duration(hours: 24)
                    : const Duration(hours: 0))
                .day)
        .map((weather) => ((weather.precipitation ?? 0)));
    final precip = (mergePrecipChance(precipList) * 100).round();

    return [
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Padding(
            padding: const EdgeInsets.only(bottom: 12, right: 14),
            child: Icon(
              weatherIconData,
              size: 36,
            )),
        Text.rich(
          TextSpan(text: '$currentTemp°F'),
          style: const TextStyle(
              fontSize: 48, fontWeight: FontWeight.w300, height: 0.9),
        ),
        Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Column(
              children: [
                Row(
                  children: [
                    const SizedBox(
                        width: 18,
                        child: Text.rich(
                          TextSpan(text: 'H: '),
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w400,
                              height: 1.25),
                        )),
                    Text.rich(
                      TextSpan(text: '$highTemp'),
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          height: 1.25),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(
                        width: 18,
                        child: Text.rich(
                          TextSpan(text: 'L: '),
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w400,
                              height: 1.25),
                        )),
                    Text.rich(
                      TextSpan(text: '$lowTemp'),
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          height: 1.25),
                    ),
                  ],
                ),
              ],
            )),
      ]),
      Text.rich(
        TextSpan(
            text:
                toBeginningOfSentenceCase((weather.weatherDescription ?? ''))),
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
      ),
      Text.rich(
        TextSpan(children: [
          const TextSpan(
              text: 'Feels like ',
              style: TextStyle(fontWeight: FontWeight.w400)),
          TextSpan(
              text: '$feelsLike°',
              style: const TextStyle(fontWeight: FontWeight.w600))
        ]),
        style: const TextStyle(
            fontSize: 16, fontWeight: FontWeight.w500, height: 1.2),
      ),
      Text.rich(
        TextSpan(children: [
          TextSpan(
              text:
                  'Precipitation ${useTomorrowPrecip ? 'tomorrow' : 'today'}: ',
              style: const TextStyle(fontWeight: FontWeight.w400)),
          TextSpan(
              text: '$precip%',
              style: const TextStyle(fontWeight: FontWeight.w600))
        ]),
        style: const TextStyle(
            fontSize: 16, fontWeight: FontWeight.w500, height: 1),
      )
    ];
  }

  Widget stockChart(Stock stock) {
    final positive = stock.current >= stock.prevClose;

    final stockMax = max(stock.chartData.max, stock.prevClose);
    final stockMin = min(stock.chartData.min, stock.prevClose);
    final chartDataLen = stock.chartData.length;
    final color = positive ? stockGreen : stockRed;

    const endGraph = 0.92;
    const startGraph = 0.07;
    const graphLen = endGraph - startGraph;

    var percentOfGraph = (chartDataLen / 391) * graphLen + startGraph + 0.01;
    if (percentOfGraph > 1) percentOfGraph = 1;
    var startPercent = percentOfGraph - 0.001 < 0 ? 0 : percentOfGraph - 0.001;
    var endPercent = percentOfGraph + 0.001 > 1 ? 1 : percentOfGraph + 0.001;
    startPercent = min(0.9, startPercent);
    percentOfGraph = min(0.9, percentOfGraph);
    endPercent = min(0.9, endPercent);
    return Container(
        width: 90,
        height: 45,
        child: Chart(
          padding: (unused) => EdgeInsets.zero,
          data: stock.chartData.mapIndexedWithLength((index, value, length) {
            var prevClose = stock.prevClose;
            if (index == 0) {
              prevClose = stockMin;
              value = stockMin;
            }
            if (index == length - 1 && length == 391) {
              prevClose = stockMax;
              value = stockMax;
            }
            return {'index': index, 'price': value, 'prevClose': prevClose};
          }).expandIndexedWithLength((index, value, length) {
            if (index == length - 1 && length != 391) {
              final numToFill = 391 - length;
              final addlValues = List.generate(numToFill, (index) {
                var prevClose = stock.prevClose;
                if (index == numToFill - 1) prevClose = stockMax;
                return {
                  'index': index + length,
                  'price': value['price']!,
                  'prevClose': prevClose,
                };
              });
              return [value, ...addlValues];
            } else {
              return [value];
            }
          }).toList(),
          variables: {
            'index': Variable(
              accessor: (Map map) => map['index'] as num,
            ),
            'price': Variable(
              accessor: (Map map) => map['price'] as num,
            ),
            'prevClose': Variable(
              accessor: (Map map) => map['prevClose'] as num,
            ),
          },
          marks: [
            LineMark(
              position: Varset("index") * Varset("price"),
              gradient: GradientEncode(
                  value: LinearGradient(stops: [
                0,
                0.095,
                0.0950001,
                startPercent as double,
                percentOfGraph,
                endPercent as double,
                endPercent + 0.00001,
                1
              ], colors: [
                Colors.transparent,
                Colors.transparent,
                color,
                color,
                color,
                color,
                Colors.transparent,
                Colors.transparent,
              ])),
            ),
            LineMark(
                position: Varset("index") * Varset("prevClose"),
                gradient: GradientEncode(
                    value: const LinearGradient(stops: [
                  0,
                  0.095,
                  0.0950001,
                  0.905,
                  0.90500001,
                  1
                ], colors: [
                  Colors.transparent,
                  Colors.transparent,
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                  Colors.transparent,
                ])),
                size: SizeEncode(value: 1),
                shape: ShapeEncode(value: BasicLineShape(dash: [2]))),
          ],
        ));
  }

  TableRow stockWidget(Stock stock) {
    final sign = stock.current - stock.prevClose >= 0 ? '+' : '-';
    return TableRow(children: [
      SizedBox(
          width: 70,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text.rich(TextSpan(
                text: stock.ticker,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    height: 1.2,
                    color: context.colorScheme.onSecondaryContainer))),
            Text.rich(TextSpan(
                text: '\$${stock.current.toStringAsFixed(2)}',
                style: TextStyle(
                    fontSize: 16,
                    height: 1.2,
                    color: context.colorScheme.onSecondaryContainer))),
          ])),
      stockChart(stock),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.rich(TextSpan(
            text:
                '$sign${(((stock.current - stock.prevClose).abs() / stock.prevClose) * 100).toStringAsFixed(2)}%',
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                height: 1.2,
                color: context.colorScheme.onSecondaryContainer))),
        Text.rich(TextSpan(
            text:
                '$sign\$${(stock.current - stock.prevClose).abs().toStringAsFixed(2)}',
            style: TextStyle(
                fontSize: 16,
                height: 1.2,
                color: context.colorScheme.onSecondaryContainer))),
      ])
    ]);
  }

  Widget stocksWidget(List<Stock> stocks) {
    return Table(
        columnWidths: const <int, TableColumnWidth>{
          0: IntrinsicColumnWidth(),
          1: IntrinsicColumnWidth(),
          2: IntrinsicColumnWidth(),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: stocks
            .map((stock) => stockWidget(stock))
            .expandIndexedWithLength((index, value, length) => [
                  value,
                  if (index < length - 1)
                    TableRow(
                        children: Iterable.generate(value.children.length,
                            (unused) => const SizedBox(height: 4)).toList())
                ])
            .toList());
  }

  TableRow calendarEventWidget(calendar.Event event) {
    final dateFormatter = DateFormat('EEE, MMM d');
    final timeFormatter = DateFormat('h:mma');

    final start = eventStartTime(event);
    final end = eventEndTime(event);

    String startDate = dateFormatter.format(start);
    String? startTime;
    String? endDate;
    String? endTime;

    if (!isAllDayEvent(event)) {
      startTime = timeFormatter.format(start);
      endTime = timeFormatter.format(end);
    }
    if (isMultidayEvent(event)) endDate = dateFormatter.format(end);

    final startWidget = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        RichText(
            text: TextSpan(
                text: startDate,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    height: 1,
                    color: context.colorScheme.onSurfaceVariant))),
        if (startTime != null) const SizedBox(width: 7),
        if (startTime != null)
          RichText(
              text: TextSpan(
                  text: startTime,
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      height: 1,
                      color: context.colorScheme.onSurfaceVariant))),
        if (endDate != null && isAllDayEvent(event)) ...<Widget>[
          RichText(
              text: TextSpan(
                  text: ' - ',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      height: 1,
                      color: context.colorScheme.onSurfaceVariant))),
          RichText(
              text: TextSpan(
                  text: endDate,
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      height: 1,
                      color: context.colorScheme.onSurfaceVariant))),
        ]
      ],
    );
    final endWidget = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (endDate != null && !isAllDayEvent(event))
          RichText(
              text: TextSpan(
                  text: endDate,
                  style: TextStyle(
                      fontWeight: FontWeight.normal,
                      fontSize: 12,
                      height: 1,
                      color: context.colorScheme.onSurfaceVariant))),
        if (endTime != null) const SizedBox(width: 5),
        if (endTime != null)
          RichText(
              text: TextSpan(
                  text: endTime,
                  style: TextStyle(
                      fontWeight: FontWeight.normal,
                      fontSize: 12,
                      height: 1,
                      color: context.colorScheme.onSurfaceVariant))),
        const SizedBox(width: 0.5)
      ],
    );

    return TableRow(children: [
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [startWidget, endWidget],
      ),
      const SizedBox(
        width: 16,
        height: 30,
      ),
      Padding(
          padding: const EdgeInsets.only(top: 1),
          child: SizedBox(
              width: 484,
              child: RichText(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                      text: event.summary ?? '',
                      style: TextStyle(
                          fontWeight: FontWeight.normal,
                          fontSize: 18,
                          height: 1,
                          color: context.colorScheme.onSurfaceVariant))))),
    ]);
  }

  bool showCalendarEvent(calendar.Event event) {
    return !(event.summary ?? '').contains('?');
  }

  bool isAllDayEvent(calendar.Event event) {
    return event.start?.date != null;
  }

  bool isMultidayEvent(calendar.Event event) {
    if (isAllDayEvent(event)) {
      return eventEndTime(event).difference(eventStartTime(event)) >
          const Duration(hours: 24);
    } else {
      final start = eventStartTime(event);
      final end = eventEndTime(event);
      return end.day != start.day ||
          end.difference(start) > const Duration(hours: 24);
    }
  }

  DateTime eventStartTime(calendar.Event event) {
    var dateTime = event.start?.date;
    dateTime ??= event.start?.dateTime;
    dateTime ??= DateTime.now().add(const Duration(days: 5 * 365));
    return dateTime.toLocal();
  }

  DateTime eventEndTime(calendar.Event event) {
    var dateTime = event.end?.date;
    dateTime ??= event.end?.dateTime;
    dateTime ??= DateTime.now().add(const Duration(days: 5 * 365));
    return dateTime.toLocal();
  }

  Widget calendarWidget(List<calendar.Event> events) {
    return Container(
        width: 707,
        child: Row(children: [
          const Spacer(),
          Table(
              columnWidths: const <int, TableColumnWidth>{
                0: IntrinsicColumnWidth(),
                1: IntrinsicColumnWidth(),
                2: IntrinsicColumnWidth(),
              },
              // border: TableBorder.all(),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: events
                  .where(showCalendarEvent)
                  .sortedBy(eventStartTime)
                  .take(5)
                  .map(calendarEventWidget)
                  .toList()),
          const Spacer(),
        ]));
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.leanBack);
    final theme = Theme.of(context);

    return FutureBuilder(
        future: _data,
        builder: (BuildContext context, AsyncSnapshot<List<dynamic>> snapshot) {
          Widget child;
          if (snapshot.hasData) {
            child = Container(
                height: 768,
                child: Column(children: [
                  Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(top: 8),
                      color: Theme.of(context).colorScheme.surfaceVariant,
                      child: SizedBox(
                          height: 580,
                          child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                              child: timeLayout(
                                  snapshot.data![0] as List<Stop>)))),
                  const SizedBox(height: 8),
                  if (user == null)
                    Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: MaterialButton(
                            onPressed: () {
                              _googleSignIn
                                  .signIn()
                                  .then((value) => user = value);
                            },
                            child: const Text('Sign in with Google'))),
                  if (user != null)
                    Card(
                        elevation: 0,
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        child: SizedBox(
                            height: 160,
                            child: Column(children: [
                              const Spacer(),
                              Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 4, 12, 4),
                                  child: calendarWidget(snapshot.data![3]
                                      as List<calendar.Event>)),
                            ]))),
                ]));
          } else if (snapshot.hasError) {
            child = Column(children: [
              const Icon(
                Icons.error_outline,
                color: Colors.red,
                size: 60,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text('Error: ${snapshot.error}'),
              ),
            ]);
          } else {
            child = const Column(children: [
              SizedBox(height: 200),
              SizedBox(
                width: 60,
                height: 60,
                child: CircularProgressIndicator(),
              ),
              Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text('Loading...'),
              ),
            ]);
          }

          List<Weather>? weather;
          List<Stock>? stocks;

          if (snapshot.hasData) {
            weather = snapshot.data![1] as List<Weather>;
            stocks = snapshot.data![2] as List<Stock>;
          }

          return Scaffold(
            body: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                    width: 261,
                    height: 768,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                              height: 588,
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Padding(
                                        padding: const EdgeInsets.only(
                                            top: 8, left: 12),
                                        child: Text.rich(
                                          TextSpan(
                                              text: DateFormat('h:mm a')
                                                  .format(DateTime.now())),
                                          style: const TextStyle(
                                              height: 1.0,
                                              fontSize: 48,
                                              fontWeight: FontWeight.w200),
                                        )),
                                    Padding(
                                        padding: const EdgeInsets.only(
                                            left: 15, right: 3),
                                        child: FittedBox(
                                          fit: BoxFit.fitWidth,
                                          child: Text.rich(
                                            TextSpan(
                                                text: DateFormat('EEEE, MMMM d')
                                                    .format(DateTime.now())),
                                            style: const TextStyle(
                                                height: 1,
                                                fontSize: 24,
                                                fontWeight: FontWeight.w300),
                                          ),
                                        )),
                                    const Spacer(),
                                    const Spacer(),
                                    const Spacer(),
                                    const Spacer(),
                                    if (weather != null)
                                      Padding(
                                          padding:
                                              const EdgeInsets.only(left: 15),
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children:
                                                  weatherWidget(weather))),
                                    const Spacer(),
                                    const Spacer(),
                                    const Spacer(),
                                    const Spacer(),
                                    const Spacer(),
                                    if (weather != null)
                                      Card(
                                          elevation: 0,
                                          margin:
                                              const EdgeInsets.only(left: 15),
                                          color: Theme.of(context)
                                              .colorScheme
                                              .secondaryContainer,
                                          child: Padding(
                                              padding: const EdgeInsets.only(
                                                  top: 10, bottom: 10),
                                              child: Row(children: [
                                                const Spacer(),
                                                Table(
                                                    columnWidths: const <int,
                                                        TableColumnWidth>{
                                                      0: IntrinsicColumnWidth(),
                                                      1: IntrinsicColumnWidth(),
                                                      2: IntrinsicColumnWidth(),
                                                      3: IntrinsicColumnWidth(),
                                                      4: IntrinsicColumnWidth(),
                                                      5: IntrinsicColumnWidth(),
                                                      6: IntrinsicColumnWidth(),
                                                    },
                                                    defaultVerticalAlignment:
                                                        TableCellVerticalAlignment
                                                            .middle,
                                                    children: weather
                                                        .skip(1)
                                                        .take(6)
                                                        .map(forecastWidget)
                                                        .expandIndexedWithLength(
                                                            (index, value,
                                                                    length) =>
                                                                [
                                                                  value,
                                                                  if (index <
                                                                      length -
                                                                          1)
                                                                    TableRow(
                                                                        children: Iterable.generate(
                                                                            value
                                                                                .children.length,
                                                                            (unused) =>
                                                                                const SizedBox(height: 10)).toList())
                                                                ])
                                                        .toList()),
                                                const Spacer()
                                              ])))
                                  ])),
                          const SizedBox(
                            height: 12,
                          ),
                          if (stocks != null && showStocks())
                            Padding(
                                padding:
                                    const EdgeInsets.only(left: 15, bottom: 0),
                                child: Card(
                                    elevation: 0,
                                    margin: EdgeInsets.zero,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer,
                                    child: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                            0, 8, 4, 8),
                                        child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              stocksWidget(stocks)
                                            ])))),
                          if (showStocks()) const Spacer(),
                          if (!showStocks())
                            ...Iterable.generate(9, (unused) => const Spacer()),
                          if (DateTime.now().difference(lastUpdated).inSeconds >
                              90)
                            Padding(
                                padding:
                                    const EdgeInsets.only(left: 16, bottom: 4),
                                child: Text(
                                    'Last updated: ${DateFormat('h:mm a').format(lastUpdated)}'))
                        ])),
              ]),
              const Spacer(),
              Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [child]),
              const Spacer(),
            ]),
          );
        });
  }
}
