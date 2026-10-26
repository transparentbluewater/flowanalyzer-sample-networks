// Generates the "Medium Network" sample the app ships
// (assets/samples/example2.inp): a SYNTHETIC water distribution network laid
// along the real streets of the town centre of Tiradentes, Minas Gerais,
// Brazil (D-31, M-047). Street layout from OpenStreetMap (ODbL); every
// hydraulic asset (sources, diameters, demands, patterns) is invented.
//
// Two stages:
//
//   1. fetch (online, run once; its output is committed):
//        dart run tool/generate_tiradentes_sample.dart --fetch <overpass.json>
//      Reads a raw Overpass download, keeps the streets inside [_bbox], builds
//      the street graph (nodes at intersections and street ends, the street
//      geometry as vertices, simplified to [_simplifyMeters]), keeps its
//      largest connected part, cuts streets longer than [_splitMeters] with
//      intermediate nodes, asks OpenTopoData (SRTM 30 m) for the ground level
//      of every graph node and of two grids of candidate sites for the
//      sources (around the highest street, and up the Serra de São José to
//      the north-west), and writes the small fixture [_fixturePath].
//      The raw download is NOT kept in the repo. To get it again:
//        curl -s -A "<your app/contact>" https://overpass-api.de/api/interpreter \
//          --data-urlencode 'data=[out:json][timeout:60];
//            way["highway"~"^(residential|tertiary|secondary|primary|unclassified|living_street|pedestrian|service)$"]
//              (-21.1210,-44.1850,-21.1050,-44.1690);(._;>;);out body;' \
//          -o tiradentes_osm.json
//      (OSM changes over time: a new download gives a slightly different graph
//      and therefore a different sample; the committed fixture pins this one.)
//
//   2. build (offline, deterministic; the default):
//        dart run tool/generate_tiradentes_sample.dart [fixture.json] [output.inp]
//      Defaults: tool/data/tiradentes_streets.json -> assets/samples/example2.inp
//      Projects the graph to WGS 84 / UTM zone 23S (EPSG:32723, metres) with
//      the app's own projection (lib/shared/geo/utm.dart) and invents the
//      hydraulics. test/sample_example2_test.dart checks that the shipped file
//      is exactly this output.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flowanalyzer/shared/geo/utm.dart';

const _fixturePath = 'tool/data/tiradentes_streets.json';

/// The licence of the street data (ODbL 1.0) and OSM's copyright page
/// (LEG-003): written in the sample's header and in the fixture.
const _odblUri = 'https://opendatacommons.org/licenses/odbl/1-0/';
const _osmCopyright = 'https://www.openstreetmap.org/copyright';
const _defaultOut = 'assets/samples/example2.inp';

/// South, west, north, east (degrees): the town centre of Tiradentes.
const _bbox = (s: -21.1210, w: -44.1850, n: -21.1050, e: -44.1690);

/// Street kinds that carry a main. Driveways are left out.
const _highways = {
  'primary',
  'secondary',
  'tertiary',
  'unclassified',
  'residential',
  'living_street',
  'pedestrian',
  'service',
};

/// Douglas-Peucker tolerance for the street geometry (metres).
const _simplifyMeters = 1.5;

/// A street longer than this (m) gets intermediate nodes, each part at most
/// [_partMeters] long.
const _splitMeters = 400.0;
const _partMeters = 300.0;

const _utmZone = 23; // WGS 84 / UTM zone 23S = EPSG:32723

// ---------------------------------------------------------------------------
// Stage 1: fetch
// ---------------------------------------------------------------------------

double _metersBetween(List<double> a, List<double> b) {
  const r = 6371008.8;
  final p1 = a[0] * math.pi / 180, p2 = b[0] * math.pi / 180;
  final dp = p2 - p1, dl = (b[1] - a[1]) * math.pi / 180;
  final h = math.pow(math.sin(dp / 2), 2) +
      math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}

/// Douglas-Peucker on lat/lon points, distances in local metres.
List<List<double>> _simplify(List<List<double>> pts, double tol) {
  if (pts.length <= 2) return pts;
  final lat0 = pts.first[0] * math.pi / 180;
  (double, double) xy(List<double> p) => (
        p[1] * math.pi / 180 * 6371008.8 * math.cos(lat0),
        p[0] * math.pi / 180 * 6371008.8,
      );
  final keep = List<bool>.filled(pts.length, false)
    ..[0] = true
    ..[pts.length - 1] = true;
  void rec(int i, int j) {
    if (j <= i + 1) return;
    final (ax, ay) = xy(pts[i]);
    final (bx, by) = xy(pts[j]);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var best = -1.0;
    var at = -1;
    for (var k = i + 1; k < j; k++) {
      final (px, py) = xy(pts[k]);
      double d;
      if (len2 == 0) {
        d = math.sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
      } else {
        final t = (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
        final qx = ax + t * dx, qy = ay + t * dy;
        d = math.sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy));
      }
      if (d > best) {
        best = d;
        at = k;
      }
    }
    if (best > tol) {
      keep[at] = true;
      rec(i, at);
      rec(at, j);
    }
  }

  rec(0, pts.length - 1);
  return [
    for (var k = 0; k < pts.length; k++)
      if (keep[k]) pts[k],
  ];
}

Future<Map<int, double>> _srtm(List<(int, double, double)> pts) async {
  final out = <int, double>{};
  final client = HttpClient()..userAgent = 'FlowAnalyzer-sample-generator/1.0';
  try {
    for (var i = 0; i < pts.length; i += 100) {
      final batch = pts.sublist(i, math.min(i + 100, pts.length));
      final locations = batch
          .map((p) => '${p.$2.toStringAsFixed(6)},${p.$3.toStringAsFixed(6)}')
          .join('|');
      final uri = Uri.https('api.opentopodata.org', '/v1/srtm30m',
          {'locations': locations, 'interpolation': 'bilinear'});
      final req = await client.getUrl(uri);
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw HttpException('OpenTopoData ${res.statusCode}: $body', uri: uri);
      }
      final results = (jsonDecode(body) as Map)['results'] as List;
      for (var k = 0; k < batch.length; k++) {
        final z = (results[k] as Map)['elevation'];
        if (z is! num) throw StateError('no elevation for ${batch[k]}');
        out[batch[k].$1] = z.toDouble();
      }
      // OpenTopoData's public API: at most 1 request per second.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
    }
  } finally {
    client.close();
  }
  return out;
}

List<double> _r7(List<double> p) => [
      double.parse(p[0].toStringAsFixed(7)),
      double.parse(p[1].toStringAsFixed(7)),
    ];

Future<void> _fetch(String overpassPath) async {
  final raw = jsonDecode(File(overpassPath).readAsStringSync()) as Map;
  final elements = (raw['elements'] as List).cast<Map>();
  final pos = <int, List<double>>{
    for (final e in elements)
      if (e['type'] == 'node')
        e['id'] as int: [(e['lat'] as num).toDouble(), (e['lon'] as num).toDouble()],
  };
  bool inside(int id) {
    final p = pos[id]!;
    return p[0] >= _bbox.s && p[0] <= _bbox.n && p[1] >= _bbox.w && p[1] <= _bbox.e;
  }

  // Runs of consecutive in-box nodes of every kept street, in id order.
  final ways = [
    for (final e in elements)
      if (e['type'] == 'way') e,
  ]..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
  final runs = <(int, String, List<int>)>[];
  for (final w in ways) {
    final tags = (w['tags'] as Map?) ?? const {};
    if (!_highways.contains(tags['highway'])) continue;
    if (tags['service'] == 'driveway' || tags['service'] == 'parking_aisle') {
      continue;
    }
    var cur = <int>[];
    for (final id in (w['nodes'] as List).cast<int>()) {
      if (inside(id)) {
        cur.add(id);
      } else {
        if (cur.length > 1) runs.add((w['id'] as int, tags['highway'] as String, cur));
        cur = <int>[];
      }
    }
    if (cur.length > 1) runs.add((w['id'] as int, tags['highway'] as String, cur));
  }

  // Graph nodes: run ends and nodes shared by two or more runs.
  final uses = <int, int>{};
  for (final (_, _, r) in runs) {
    for (final id in r) {
      uses[id] = (uses[id] ?? 0) + 1;
    }
    uses[r.first] = (uses[r.first] ?? 0) + 1;
    uses[r.last] = (uses[r.last] ?? 0) + 1;
  }
  final isNode = {for (final e in uses.entries) if (e.value >= 2) e.key};

  // Edges between consecutive graph nodes along each run.
  final edges = <(int, String, List<int>)>[];
  for (final (way, kind, r) in runs) {
    var cur = <int>[r.first];
    for (final id in r.skip(1)) {
      cur.add(id);
      if (isNode.contains(id)) {
        if (cur.first != cur.last) edges.add((way, kind, cur));
        cur = <int>[id];
      }
    }
  }

  // Largest connected part.
  final adj = <int, Set<int>>{};
  for (final (_, _, e) in edges) {
    adj.putIfAbsent(e.first, () => {}).add(e.last);
    adj.putIfAbsent(e.last, () => {}).add(e.first);
  }
  final seen = <int>{};
  var best = <int>{};
  for (final v in adj.keys.toList()..sort()) {
    if (seen.contains(v)) continue;
    final comp = <int>{};
    final stack = [v];
    while (stack.isNotEmpty) {
      final x = stack.removeLast();
      if (!comp.add(x)) continue;
      stack.addAll(adj[x]!);
    }
    seen.addAll(comp);
    if (comp.length > best.length) best = comp;
  }
  final keptEdges = [
    for (final e in edges)
      if (best.contains(e.$3.first)) e,
  ];

  // A street longer than [_splitMeters] is cut into equal parts of at most
  // [_partMeters] (HID-006): the new nodes take synthetic negative ids and
  // their own SRTM level.
  var nextId = -1;
  final graphEdges = <(int, String, int, int, List<List<double>>)>[];
  for (final (way, kind, e) in keptEdges) {
    final pts = [for (final id in e) pos[id]!];
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum.last + _metersBetween(pts[i - 1], pts[i]));
    }
    final len = cum.last;
    if (len <= _splitMeters) {
      graphEdges.add((way, kind, e.first, e.last, pts));
      continue;
    }
    final parts = (len / _partMeters).ceil();
    var from = e.first;
    var cur = <List<double>>[pts.first];
    var k = 1;
    for (var i = 1; i < pts.length; i++) {
      while (k < parts && cum[i] > len * k / parts) {
        final t = (len * k / parts - cum[i - 1]) / (cum[i] - cum[i - 1]);
        final p = [
          pts[i - 1][0] + t * (pts[i][0] - pts[i - 1][0]),
          pts[i - 1][1] + t * (pts[i][1] - pts[i - 1][1]),
        ];
        final id = nextId--;
        pos[id] = p;
        graphEdges.add((way, kind, from, id, [...cur, p]));
        from = id;
        cur = [p];
        k++;
      }
      cur.add(pts[i]);
    }
    graphEdges.add((way, kind, from, e.last, cur));
  }
  final nodeIds = {
    for (final (_, _, a, b, _) in graphEdges) ...[a, b],
  }.toList()
    ..sort();

  stderr.writeln('graph: ${nodeIds.length} nodes, ${graphEdges.length} edges; '
      'asking OpenTopoData (SRTM 30 m)...');
  final z = await _srtm([for (final id in nodeIds) (id, pos[id]![0], pos[id]![1])]);

  // Candidate sites for the sources, with their SRTM level: a fine grid
  // around the highest street node (the tank) and a coarser one up the slope
  // of the Serra de São José to the north-west (the reservoir). The build
  // stage picks from them (HID-001).
  final top = nodeIds.reduce((p, q) => z[q]! > z[p]! ? q : p);
  final (topLat, topLon) = (pos[top]![0], pos[top]![1]);
  final tankGrid = [
    for (var i = -4; i <= 4; i++)
      for (var j = -4; j <= 4; j++) [topLat + i * 0.0003, topLon + j * 0.0003],
  ];
  final reservoirGrid = [
    for (var i = 3; i <= 12; i++)
      for (var j = -20; j <= -8; j++) [topLat + i * 0.001, topLon + j * 0.001],
  ];
  Future<List<List<double>>> sites(List<List<double>> grid) async {
    final zs = await _srtm([
      for (var k = 0; k < grid.length; k++) (k, grid[k][0], grid[k][1]),
    ]);
    return [
      for (var k = 0; k < grid.length; k++)
        [..._r7(grid[k]), double.parse(zs[k]!.toStringAsFixed(1))],
    ];
  }

  // And a finer grid over the whole slope between the two, for the ground
  // under the gravity main (its clearance and its lowest point, HID-007).
  final slopeGrid = [
    for (var i = 0; i <= 24; i++)
      for (var j = -40; j <= 0; j++) [topLat + i * 0.0005, topLon + j * 0.0005],
  ];
  final tankSites = await sites(tankGrid);
  final reservoirSites = await sites(reservoirGrid);
  final slopeSites = await sites(slopeGrid);

  final fixture = {
    'about': 'Street graph of the town centre of Tiradentes (MG, Brazil) for '
        'the synthetic FlowAnalyzer sample, with candidate sites for its '
        'sources. Street layout (c) OpenStreetMap contributors, ODbL 1.0, '
        '$_odblUri - $_osmCopyright; ground '
        'levels: SRTM 30 m via OpenTopoData. Generated by '
        'tool/generate_tiradentes_sample.dart --fetch.',
    'osmBase': (raw['osm3s'] as Map?)?['timestamp_osm_base'],
    'bbox': [_bbox.s, _bbox.w, _bbox.n, _bbox.e],
    'nodes': [
      for (final id in nodeIds)
        [id, ..._r7(pos[id]!), double.parse(z[id]!.toStringAsFixed(1))],
    ],
    'edges': [
      for (final (way, kind, a, b, pts) in graphEdges)
        [
          way,
          kind,
          a,
          b,
          [
            for (final p in _simplify(pts, _simplifyMeters).sublist(1)
              ..removeLast())
              _r7(p),
          ],
        ],
    ],
    'tankSites': tankSites,
    'reservoirSites': reservoirSites,
    'slopeSites': slopeSites,
  };
  File(_fixturePath)
    ..createSync(recursive: true)
    ..writeAsStringSync('${const JsonEncoder.withIndent(null).convert(fixture)}\n');
  stderr.writeln('wrote $_fixturePath');
  stderr.writeln('ground ${z.values.reduce(math.min)}..'
      '${z.values.reduce(math.max)} m; reservoir sites '
      '${reservoirSites.map((s) => s[2]).reduce(math.min)}..'
      '${reservoirSites.map((s) => s[2]).reduce(math.max)} m');
}

// ---------------------------------------------------------------------------
// Stage 2: build
// ---------------------------------------------------------------------------

// The hydraulics are invented, but laid out the way a small hillside town is
// often served, and placed on the ground SRTM gives (HID-001): the streets
// span ~80 m of ground level (893–974 m), more than one pressure zone holds
// within ~15–60 m, so there are two.
//   * Source: a ground-level reservoir (water surface [_reservoirAboveGround]
//     above its ground, e.g. a treatment plant's clear well) on the slope of
//     the Serra de São José, north-west of the town, feeds through a gravity
//     main of [_mainDiameter] an elevated tank (a low tower) on the hilltop
//     next to the highest street. Of the candidate sites, the reservoir is
//     the one whose main, at the average demand, leaves the tank at
//     [_tankTargetLevel]: the tank then fills at night and drains at the
//     peaks, and its daily cycle closes ([_tank]).
//   * High zone (ground >= [_zoneSplit]): served by the tank.
//   * Low zone (the rest): fed from the high zone through two pressure
//     reducing valves that hold [_lowZoneHead] downstream. Each sits a few
//     metres long ([_prvLength]) where its street crosses ground [_prvGround]
//     (interpolated between the street's ends); the other streets that cross
//     the zone boundary have a closed pipe.
//   * A stranded piece of a zone (a dead-end street that dips into the other
//     zone) is left out of the network; two streets joining the same two
//     nodes (a dual carriageway) become one pipe.
// Pipes of the supply tree are sized for the peak hour of the maximum day
// ([_maxDayFactor], [_designVelocity]); the rest take a minimum by street
// kind (63 mm in service lanes, footways and dead ends).

/// Street nodes joined by a street shorter than this (m) become one node
/// (OSM nodes a step apart at a roundabout or a kerb).
const _mergeMeters = 3.0;

/// Ground level (m) that separates the two pressure zones.
const _zoneSplit = 935.0;

/// Hydraulic grade the PRVs hold in the low zone (m).
const _lowZoneHead = 952.0;

/// Ground level (m) at which a PRV is placed along its street, and the
/// length it is drawn with (m).
const _prvGround = 936.0;
const _prvLength = 3.0;

/// The tank: bottom level, initial, minimum and maximum water level,
/// diameter (m). The initial level is the level at 0:00 of the periodic
/// daily cycle (EPANET 2.3.5 over 96 h), so the 24 h cycle closes.
const _tank = (bottom: 990.0, init: 2.22, min: 0.5, max: 6.0, diameter: 10.0);

/// Tank site: the highest candidate within [_tankSiteRadius] m of the highest
/// street node, on ground of at least [_tankSiteMinGround] m, with a tower of
/// at most [_tankMaxTower] m under the bottom.
const _tankSiteRadius = 100.0;
const _tankSiteMinGround = 970.0;
const _tankMaxTower = 20.0;

/// Reservoir site: ground of at least [_reservoirMinGround] m, at least
/// [_reservoirMinDistance] m from the tank; water surface this far above it.
const _reservoirMinGround = 1000.0;
const _reservoirMinDistance = 1000.0;
const _reservoirAboveGround = 2.0;

/// Level (above the bottom) the tank floats at when the main carries the
/// average demand (m).
const _tankTargetLevel = 3.0;

/// The gravity main from the reservoir to the tank (mm).
const _mainDiameter = 100.0;

/// The ground under the main must stay this far below its hydraulic grade (m)
/// at every candidate site next to it.
const _mainClearance = 5.0;

/// Average-day demand per km of street (L/s), shared between the two ends.
const _demandPerKm = 0.45;

/// Junctions this close to the network's centre (m) use the commercial
/// pattern (shops, inns, restaurants); the rest the residential one.
const _centreRadius = 300.0;

/// Peak-hour velocity used to size the supply tree (m/s), on the demand of
/// the maximum day ([_maxDayFactor] times the average day).
const _designVelocity = 0.9;
const _maxDayFactor = 1.3;

/// Commercial nominal diameters (mm).
const _diameters = [63.0, 75.0, 100.0, 150.0, 200.0, 250.0];

/// 24 hourly demand multipliers, average exactly 1 (checked when building).
const _residential = [
  0.60, 0.50, 0.45, 0.40, 0.45, 0.60, 0.90, 1.30, 1.45, 1.40, 1.25, 1.20, //
  1.25, 1.20, 1.10, 1.00, 1.05, 1.20, 1.40, 1.50, 1.30, 1.05, 0.85, 0.60,
];
const _commercial = [
  0.40, 0.35, 0.30, 0.30, 0.30, 0.40, 0.70, 1.10, 1.40, 1.50, 1.50, 1.55, //
  1.50, 1.40, 1.30, 1.30, 1.30, 1.45, 1.40, 1.30, 1.20, 0.90, 0.70, 0.45,
];

class _Node {
  _Node(this.osm, this.x, this.y, this.z);
  final int osm;
  final double x, y, z;
  late String id;
  bool high = false;
  double demand = 0;
  String pattern = '1';
}

class _Edge {
  _Edge(this.kind, this.a, this.b, this.vertices, this.length);
  final String kind;
  _Node a, b;
  List<(double, double)> vertices;
  final double length;
  late String id;
  double diameter = 0;
  bool closed = false;
  bool prv = false;

  /// The drawn polyline, from [a] to [b].
  List<(double, double)> get points => [(a.x, a.y), ...vertices, (b.x, b.y)];
}

double _round(double v, int d) => double.parse(v.toStringAsFixed(d));

String _fmt(double v, [int d = 2]) {
  var s = v.toStringAsFixed(d);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s == '-0' ? '0' : s;
}

List<double> _averageOne(List<double> m) {
  final mean = m.reduce((a, b) => a + b) / m.length;
  if (m.length != 24 || (mean - 1).abs() > 1e-9) {
    throw StateError('a pattern needs 24 multipliers averaging 1 (got $mean)');
  }
  return m;
}

/// Connected parts of [nodes] using only [edges] whose ends are both in it.
List<Set<_Node>> _parts(Iterable<_Node> nodes, Iterable<_Edge> edges) {
  final set = nodes.toSet();
  final adj = <_Node, List<_Node>>{for (final n in set) n: []};
  for (final e in edges) {
    if (set.contains(e.a) && set.contains(e.b)) {
      adj[e.a]!.add(e.b);
      adj[e.b]!.add(e.a);
    }
  }
  final seen = <_Node>{};
  final out = <Set<_Node>>[];
  for (final n in set) {
    if (seen.contains(n)) continue;
    final part = <_Node>{};
    final stack = [n];
    while (stack.isNotEmpty) {
      final x = stack.removeLast();
      if (!part.add(x)) continue;
      stack.addAll(adj[x]!);
    }
    seen.addAll(part);
    out.add(part);
  }
  out.sort((p, q) => q.length.compareTo(p.length));
  return out;
}

double _dist(_Node p, _Node q) => math.sqrt(
    (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y));

/// The smallest diameter that carries [q] (L/s) at no more than [v] m/s.
double _size(double q, double v, double minimum) {
  for (final d in _diameters) {
    if (d < minimum) continue;
    final area = math.pi * math.pow(d / 1000, 2) / 4;
    if (q / 1000 / area <= v) return d;
  }
  return _diameters.last;
}

double _roughness(double d) => d >= 200 ? 130 : 140;

/// Hazen-Williams head loss (m) of [q] L/s in [length] m of [d] mm pipe.
double _headLoss(double q, double length, double d) =>
    10.67 *
    length *
    math.pow(q / 1000, 1.852) /
    (math.pow(_roughness(d), 1.852) * math.pow(d / 1000, 4.871));

/// A candidate source site, projected: x, y in UTM 23S, z its SRTM ground.
_Node _site(List r) {
  final u = wgs84ToUtm((r[0] as num).toDouble(), (r[1] as num).toDouble(),
      zone: _utmZone);
  return _Node(0, _round(u.easting, 2), _round(u.northing, 2),
      (r[2] as num).toDouble());
}

/// Splits the boundary street [e] (from its high end [e.a] to its low end
/// [e.b]) where its ground reaches [_prvGround]: a pipe to a new node, the
/// PRV [_prvLength] long, a pipe on to the low end. Ground of the two new
/// nodes interpolated along the street.
List<_Edge> _splitForPrv(_Edge e) {
  final pts = e.points;
  final cum = <double>[0];
  for (var i = 1; i < pts.length; i++) {
    final dx = pts[i].$1 - pts[i - 1].$1, dy = pts[i].$2 - pts[i - 1].$2;
    cum.add(cum.last + math.sqrt(dx * dx + dy * dy));
  }
  final len = cum.last;
  final f = ((e.a.z - _prvGround) / (e.a.z - e.b.z)).clamp(0.1, 0.9);
  final s0 = f * len - _prvLength / 2, s1 = f * len + _prvLength / 2;
  (double, double) at(double s) {
    var i = 1;
    while (i < pts.length - 1 && cum[i] < s) {
      i++;
    }
    final t = (s - cum[i - 1]) / (cum[i] - cum[i - 1]);
    return (
      _round(pts[i - 1].$1 + t * (pts[i].$1 - pts[i - 1].$1), 2),
      _round(pts[i - 1].$2 + t * (pts[i].$2 - pts[i - 1].$2), 2),
    );
  }

  double ground(double s) => _round(e.a.z + (e.b.z - e.a.z) * s / len, 1);
  final (nx, ny) = at(s0);
  final (mx, my) = at(s1);
  final n = _Node(0, nx, ny, ground(s0))..high = true;
  final m = _Node(0, mx, my, ground(s1))..high = false;
  final inner = [
    for (var i = 1; i < pts.length - 1; i++) (cum[i], pts[i]),
  ];
  return [
    _Edge(e.kind, e.a, n, [for (final (c, p) in inner) if (c < s0) p],
        math.max(1.0, _round(s0, 2))),
    _Edge(e.kind, n, m, const [], _prvLength)..prv = true,
    _Edge(e.kind, m, e.b, [for (final (c, p) in inner) if (c > s1) p],
        math.max(1.0, _round(len - s1, 2))),
  ];
}

String buildTiradentesSample(String fixtureJson) {
  final fx = jsonDecode(fixtureJson) as Map;
  final byOsm = <int, _Node>{};
  for (final r in (fx['nodes'] as List).cast<List>()) {
    final u = wgs84ToUtm((r[1] as num).toDouble(), (r[2] as num).toDouble(),
        zone: _utmZone);
    byOsm[r[0] as int] = _Node(r[0] as int, _round(u.easting, 2),
        _round(u.northing, 2), (r[3] as num).toDouble());
  }
  var nodes = byOsm.values.toList();
  var edges = <_Edge>[];
  for (final r in (fx['edges'] as List).cast<List>()) {
    final a = byOsm[r[2] as int]!, b = byOsm[r[3] as int]!;
    final verts = [
      for (final v in (r[4] as List).cast<List>())
        () {
          final u = wgs84ToUtm(
              (v[0] as num).toDouble(), (v[1] as num).toDouble(),
              zone: _utmZone);
          return (_round(u.easting, 2), _round(u.northing, 2));
        }(),
    ];
    final pts = [(a.x, a.y), ...verts, (b.x, b.y)];
    var len = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final dx = pts[i].$1 - pts[i - 1].$1, dy = pts[i].$2 - pts[i - 1].$2;
      len += math.sqrt(dx * dx + dy * dy);
    }
    edges.add(_Edge(r[1] as String, a, b, verts, math.max(1.0, _round(len, 2))));
  }

  // Merge nodes a few metres apart: the shortest such street first, the node
  // with the smaller OSM id stays.
  while (true) {
    _Edge? short;
    for (final e in edges) {
      if (e.length < _mergeMeters && (short == null || e.length < short.length)) {
        short = e;
      }
    }
    if (short == null) break;
    final keep = short.a.osm < short.b.osm ? short.a : short.b;
    final drop = identical(keep, short.a) ? short.b : short.a;
    edges.remove(short);
    for (final e in edges) {
      if (identical(e.a, drop)) e.a = keep;
      if (identical(e.b, drop)) e.b = keep;
    }
    edges.removeWhere((e) => identical(e.a, e.b));
    nodes.remove(drop);
  }

  // Two streets between the same two nodes (a dual carriageway): the
  // shorter one carries the pipe.
  final byEndsKey = <String, _Edge>{};
  for (final e in edges) {
    final k = e.a.osm < e.b.osm ? '${e.a.osm}:${e.b.osm}' : '${e.b.osm}:${e.a.osm}';
    final seen = byEndsKey[k];
    if (seen == null || e.length < seen.length) byEndsKey[k] = e;
  }
  edges = [
    for (final e in edges)
      if (identical(
          byEndsKey[e.a.osm < e.b.osm
              ? '${e.a.osm}:${e.b.osm}'
              : '${e.b.osm}:${e.a.osm}'],
          e))
        e,
  ];

  // Pressure zones; a stranded piece of a zone is left out.
  for (final n in nodes) {
    n.high = n.z >= _zoneSplit;
  }
  final stranded = <_Node>{
    for (final high in [false, true])
      for (final p in _parts(nodes.where((n) => n.high == high), edges).skip(1))
        ...p,
  };
  nodes = [
    for (final n in nodes)
      if (!stranded.contains(n)) n,
  ];
  edges = [
    for (final e in edges)
      if (!stranded.contains(e.a) && !stranded.contains(e.b)) e,
  ];

  // Demands: half of each street's length to each end.
  double cx(Iterable<_Node> ns) =>
      ns.map((n) => n.x).reduce((a, b) => a + b) / ns.length;
  double cy(Iterable<_Node> ns) =>
      ns.map((n) => n.y).reduce((a, b) => a + b) / ns.length;
  final centre = _Node(0, cx(nodes), cy(nodes), 0);
  final res = _averageOne(_residential);
  final com = _averageOne(_commercial);
  final peak = {'1': res.reduce(math.max), '2': com.reduce(math.max)};
  for (final e in edges) {
    e.a.demand += e.length / 2 / 1000 * _demandPerKm;
    e.b.demand += e.length / 2 / 1000 * _demandPerKm;
  }
  for (final n in nodes) {
    n.demand = math.max(0.005, _round(n.demand, 3));
    if (_dist(n, centre) <= _centreRadius) n.pattern = '2';
  }
  final averageDemand = nodes.fold<double>(0, (s, n) => s + n.demand);

  // The tank: on the best candidate site next to the highest street node.
  final top = nodes.reduce((p, q) => q.z > p.z ? q : p);
  final tankSites = [
    for (final r in (fx['tankSites'] as List).cast<List>()) _site(r),
  ].where((s) => _dist(s, top) <= _tankSiteRadius && s.z >= _tankSiteMinGround);
  if (tankSites.isEmpty) throw StateError('no tank site');
  final tank = tankSites.reduce((p, q) => q.z > p.z ||
          (q.z == p.z && _dist(q, top) < _dist(p, top))
      ? q
      : p)
    ..id = 'T1';
  if (_tank.bottom - tank.z > _tankMaxTower || _tank.bottom < tank.z) {
    throw StateError('tank tower ${_tank.bottom - tank.z} m');
  }

  // The reservoir: the candidate whose main leaves the tank at its target
  // level at the average demand, with the ground under the main below its
  // hydraulic grade.
  final allSites = [
    for (final r in (fx['reservoirSites'] as List).cast<List>()) _site(r),
  ];
  // Ground along the slope between reservoir and tank, for the main.
  final groundSites = [
    ...allSites,
    for (final r in (fx['slopeSites'] as List).cast<List>()) _site(r),
  ];
  final target = _tank.bottom + _tankTargetLevel;
  final candidates = [
    for (final s in allSites)
      if (s.z >= _reservoirMinGround && _dist(s, tank) >= _reservoirMinDistance)
        (
          site: s,
          head: _round(s.z + _reservoirAboveGround, 1),
          length: _round(_dist(s, tank), 2),
        ),
  ]..sort((p, q) {
      double miss(({_Node site, double head, double length}) c) =>
          (c.head - _headLoss(averageDemand, c.length, _mainDiameter) - target)
              .abs();
      final c = miss(p).compareTo(miss(q));
      return c != 0 ? c : p.length.compareTo(q.length);
    });
  bool clear(({_Node site, double head, double length}) c) {
    final end = c.head - _headLoss(averageDemand, c.length, _mainDiameter);
    final dx = tank.x - c.site.x, dy = tank.y - c.site.y;
    for (final s in groundSites) {
      final t = ((s.x - c.site.x) * dx + (s.y - c.site.y) * dy) /
          (dx * dx + dy * dy);
      if (t < 0.05 || t > 0.95) continue;
      final px = c.site.x + t * dx, py = c.site.y + t * dy;
      final off = math.sqrt((s.x - px) * (s.x - px) + (s.y - py) * (s.y - py));
      if (off > 60) continue;
      if (s.z > c.head + (end - c.head) * t - _mainClearance) return false;
    }
    return true;
  }

  final source = candidates.firstWhere(clear,
      orElse: () => throw StateError('no reservoir site'));
  final reservoir = source.site..id = 'R1';
  final reservoirHead = source.head;
  final mainLength = source.length;

  // The lowest candidate ground next to the main (HID-007): the main has no
  // junctions, so its static pressure there is said in the header.
  var dipGround = double.infinity;
  {
    final dx = tank.x - reservoir.x, dy = tank.y - reservoir.y;
    for (final s in [...groundSites, tank]) {
      final t = ((s.x - reservoir.x) * dx + (s.y - reservoir.y) * dy) /
          (dx * dx + dy * dy);
      if (t < 0 || t > 1) continue;
      final px = reservoir.x + t * dx, py = reservoir.y + t * dy;
      final off = math.sqrt((s.x - px) * (s.x - px) + (s.y - py) * (s.y - py));
      if (off <= 40) dipGround = math.min(dipGround, s.z);
    }
  }

  // Zone boundary: the two shortest crossings (at least 300 m apart) get a
  // PRV, split into a few metres where the street reaches [_prvGround]; the
  // others a closed pipe.
  final crossings = edges.where((e) => e.a.high != e.b.high).toList()
    ..sort((p, q) => p.length.compareTo(q.length));
  final prvStreets = <_Edge>[];
  for (final e in crossings) {
    final low = e.a.high ? e.b : e.a;
    if (prvStreets.length < 2 &&
        prvStreets.every((p) => _dist(p.a.high ? p.b : p.a, low) >= 300)) {
      prvStreets.add(e);
    } else {
      e.closed = true;
    }
  }
  for (final e in prvStreets) {
    if (!e.a.high) {
      final t = e.a;
      e.a = e.b;
      e.b = t;
      e.vertices = e.vertices.reversed.toList();
    }
    final split = _splitForPrv(e);
    edges
      ..remove(e)
      ..addAll(split);
    nodes.addAll([split[1].a, split[1].b]);
  }
  final prvs = edges.where((e) => e.prv).toList();

  // Ids: junctions in reading order (north to south, west to east).
  nodes.sort((p, q) => p.y != q.y ? q.y.compareTo(p.y) : p.x.compareTo(q.x));
  for (var i = 0; i < nodes.length; i++) {
    nodes[i].id = 'J${i + 1}';
  }
  final index = {for (var i = 0; i < nodes.length; i++) nodes[i]: i};

  // Supply tree from the tank's street node (shortest path by length,
  // through the PRVs, never through a closed pipe); each tree pipe carries the
  // maximum-day peak demand downstream of it.
  final open = edges.where((e) => !e.closed).toList();
  final adj = <_Node, List<_Edge>>{for (final n in nodes) n: []};
  for (final e in open) {
    adj[e.a]!.add(e);
    if (!e.prv) adj[e.b]!.add(e); // a PRV only lets water from high to low
  }
  final dist = <_Node, double>{top: 0};
  final via = <_Node, _Edge>{};
  final done = <_Node>{};
  while (true) {
    _Node? u;
    for (final n in dist.keys) {
      if (done.contains(n)) continue;
      if (u == null ||
          dist[n]! < dist[u]! ||
          (dist[n] == dist[u] && index[n]! < index[u]!)) {
        u = n;
      }
    }
    if (u == null) break;
    done.add(u);
    for (final e in adj[u]!) {
      final v = identical(e.a, u) ? e.b : e.a;
      final d = dist[u]! + (e.prv ? 0 : e.length);
      if (!dist.containsKey(v) || d < dist[v]!) {
        dist[v] = d;
        via[v] = e;
      }
    }
  }
  if (done.length != nodes.length) {
    throw StateError('${nodes.length - done.length} junctions without supply');
  }
  final carried = <_Edge, double>{};
  final order = done.toList()..sort((p, q) => dist[q]!.compareTo(dist[p]!));
  final below = <_Node, double>{
    for (final n in nodes) n: n.demand * peak[n.pattern]! * _maxDayFactor,
  };
  for (final n in order) {
    final e = via[n];
    if (e == null) continue;
    final parent = identical(e.a, n) ? e.b : e.a;
    carried[e] = below[n]!;
    below[parent] = below[parent]! + below[n]!;
  }
  final totalPeak = below[top]!;
  final degree = <_Node, int>{};
  for (final e in open) {
    degree[e.a] = (degree[e.a] ?? 0) + 1;
    degree[e.b] = (degree[e.b] ?? 0) + 1;
  }
  for (final e in edges) {
    final deadEnd = degree[e.a] == 1 || degree[e.b] == 1;
    final minimum = switch (e.kind) {
      'primary' || 'secondary' || 'tertiary' => 100.0,
      'residential' => deadEnd ? 63.0 : 75.0,
      _ => 63.0,
    };
    e.diameter = e.prv
        ? _size(carried[e] ?? 0, 1.5, 75)
        : _size(carried[e] ?? 0, _designVelocity, minimum);
  }

  // Link ids: P1 the gravity main, P2 the tank's pipe, then the street pipes
  // in order of their first junction.
  final streetPipes = edges.where((e) => !e.prv).toList();
  for (final e in streetPipes) {
    if (index[e.a]! > index[e.b]!) {
      final t = e.a;
      e.a = e.b;
      e.b = t;
      e.vertices = e.vertices.reversed.toList();
    }
  }
  int byEnds(_Edge p, _Edge q) {
    final c = index[p.a]!.compareTo(index[q.a]!);
    if (c != 0) return c;
    final d = index[p.b]!.compareTo(index[q.b]!);
    return d != 0 ? d : p.length.compareTo(q.length);
  }

  streetPipes.sort(byEnds);
  for (var i = 0; i < streetPipes.length; i++) {
    streetPipes[i].id = 'P${i + 3}';
  }
  prvs.sort(byEnds);
  for (var i = 0; i < prvs.length; i++) {
    prvs[i].id = 'V${i + 1}';
  }
  final tankLength = math.max(1.0, _round(_dist(tank, top), 2));
  final tankDiameter = _size(totalPeak, _designVelocity, 150);

  String col(Object v, [int w = 12]) => '$v'.padRight(w);

  final b = StringBuffer()
    ..writeln('; Medium Network - SYNTHETIC sample network for FlowAnalyzer '
        '(demonstration only).')
    ..writeln('; Laid along the streets of the town centre of Tiradentes, '
        'Minas Gerais, Brazil, but it is NOT')
    ..writeln('; the real water system: sources, pipes, diameters, demands '
        'and patterns are invented; no real assets.')
    ..writeln('; Coordinates: WGS 84 / UTM zone 23S (EPSG:32723), metres.')
    ..writeln('; Street layout © OpenStreetMap contributors, ODbL 1.0, '
        '$_odblUri - $_osmCopyright')
    ..writeln('; Source database: <URL pending>')
    ..writeln('; Ground levels approximate (SRTM 30 m).')
    ..writeln('; P1 (gravity main, no junctions on it) crosses a dip at '
        '~${_fmt(dipGround, 0)} m: static pressure ~${_fmt(reservoirHead - dipGround, 0)} m '
        'there; choose its pipe class for that.')
    ..writeln('; Generated by tool/generate_tiradentes_sample.dart.')
    ..writeln()
    ..writeln('[TITLE]')
    ..writeln('Medium Network - synthetic sample')
    ..writeln('Q_VAR_PROJECTION=EPSG:32723')
    ..writeln()
    ..writeln('[JUNCTIONS]')
    ..writeln(';ID         Elev        Demand      Pattern');
  for (final n in nodes) {
    b.writeln(' ${col(n.id)}${col(_fmt(n.z, 1))}${col(_fmt(n.demand, 3))}${n.pattern}');
  }
  b
    ..writeln()
    ..writeln('[RESERVOIRS]')
    ..writeln(';ID         Head        Pattern')
    ..writeln(' ${col('R1')}${_fmt(reservoirHead, 1)}')
    ..writeln()
    ..writeln('[TANKS]')
    ..writeln(';ID         Elevation   InitLevel   MinLevel    MaxLevel    '
        'Diameter    MinVol')
    ..writeln(' ${col('T1')}${col(_fmt(_tank.bottom))}${col(_fmt(_tank.init))}'
        '${col(_fmt(_tank.min))}${col(_fmt(_tank.max))}${col(_fmt(_tank.diameter))}0')
    ..writeln()
    ..writeln('[PIPES]')
    ..writeln(';ID         Node1       Node2       Length      Diameter    '
        'Roughness   MinorLoss   Status');
  void pipe(String id, String a, String bb, double len, double d, bool closed) {
    b.writeln(' ${col(id)}${col(a)}${col(bb)}${col(_fmt(len))}${col(_fmt(d))}'
        '${col(_fmt(_roughness(d)))}${col('0')}${closed ? 'Closed' : 'Open'}');
  }

  pipe('P1', 'R1', 'T1', mainLength, _mainDiameter, false);
  pipe('P2', 'T1', top.id, tankLength, tankDiameter, false);
  for (final e in streetPipes) {
    pipe(e.id, e.a.id, e.b.id, e.length, e.diameter, e.closed);
  }
  b
    ..writeln()
    ..writeln('[VALVES]')
    ..writeln(';ID         Node1       Node2       Diameter    Type        '
        'Setting     MinorLoss');
  for (final e in prvs) {
    b.writeln(' ${col(e.id)}${col(e.a.id)}${col(e.b.id)}${col(_fmt(e.diameter))}'
        '${col('PRV')}${col(_fmt(_lowZoneHead - e.b.z, 1))}0');
  }
  b
    ..writeln()
    ..writeln('[PATTERNS]')
    ..writeln(';ID         Multipliers')
    ..writeln(';Residential');
  void pattern(String id, List<double> m) {
    for (var i = 0; i < m.length; i += 6) {
      b.writeln(' ${col(id)}${m.sublist(i, i + 6).map((v) => col(_fmt(v), 8)).join().trimRight()}');
    }
  }

  pattern('1', res);
  b.writeln(';Commercial (shops, inns, restaurants)');
  pattern('2', com);
  b
    ..writeln()
    ..writeln('[OPTIONS]')
    ..writeln(' Units               LPS')
    ..writeln(' Headloss            H-W')
    ..writeln(' Specific Gravity    1')
    ..writeln(' Viscosity           1')
    ..writeln(' Trials              40')
    ..writeln(' Accuracy            0.001')
    ..writeln(' Pattern             1')
    ..writeln(' Demand Multiplier   1')
    ..writeln(' Quality             None')
    ..writeln()
    ..writeln('[TIMES]')
    ..writeln(' Duration            24:00')
    ..writeln(' Hydraulic Timestep  1:00')
    ..writeln(' Quality Timestep    0:05')
    ..writeln(' Pattern Timestep    1:00')
    ..writeln(' Pattern Start       0:00')
    ..writeln(' Report Timestep     1:00')
    ..writeln(' Report Start        0:00')
    ..writeln(' Start ClockTime     12 am')
    ..writeln(' Statistic           None')
    ..writeln()
    ..writeln('[REPORT]')
    ..writeln(' Status              No')
    ..writeln(' Summary             No')
    ..writeln()
    ..writeln('[COORDINATES]')
    ..writeln(';Node       X-Coord         Y-Coord');
  for (final n in [...nodes, reservoir, tank]) {
    b.writeln(' ${col(n.id)}${col(n.x.toStringAsFixed(2), 16)}${n.y.toStringAsFixed(2)}');
  }
  b
    ..writeln()
    ..writeln('[VERTICES]')
    ..writeln(';Link       X-Coord         Y-Coord');
  for (final e in [...streetPipes, ...prvs]) {
    for (final (x, y) in e.vertices) {
      b.writeln(' ${col(e.id)}${col(x.toStringAsFixed(2), 16)}${y.toStringAsFixed(2)}');
    }
  }
  b
    ..writeln()
    ..writeln('[END]');
  return b.toString();
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--fetch') {
    if (args.length < 2) {
      stderr.writeln('usage: --fetch <overpass.json>');
      exit(64);
    }
    await _fetch(args[1]);
    return;
  }
  final input = args.isNotEmpty ? args[0] : _fixturePath;
  final output = args.length > 1 ? args[1] : _defaultOut;
  final inp = buildTiradentesSample(File(input).readAsStringSync());
  File(output).writeAsStringSync(inp);
  stderr.writeln('wrote $output');
}
