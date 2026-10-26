# FlowAnalyzer sample networks

Sample water distribution networks (EPANET `.inp`) for demonstrations, tests and tutorials of the FlowAnalyzer apps, by Transparent Blue Water LLC.
They contain **no data from any real utility or client**: every hydraulic asset is invented.

## Tiradentes (synthetic)
`tiradentes/tiradentes-synthetic.inp`: a synthetic network laid along the real streets of the town centre of Tiradentes,
Minas Gerais, Brazil. Sources, pipes, diameters, demands and patterns are invented; it is **not** the town's real water system.

- Coordinates in WGS 84 / UTM zone 23S (EPSG:32723), metres. The `[TITLE]` carries `Q_VAR_PROJECTION=EPSG:32723`, so apps that
  read that line open it in place on a map.
- Two pressure zones with PRVs, one tank, one reservoir, 96 h extended period. Ground levels approximate (SRTM 30 m).
- `tiradentes/data/tiradentes_streets.json`: the derived street database it is built from (OpenStreetMap streets, SRTM ground levels).
- sha256 of the `.inp`: `c31d0d3b44bc0248e779368531496b6896877584fe88e817e3f469870fbc7180`.

## Demo Town (synthetic)
`demo-town/`: synthetic networks laid along real streets of the centre of Aguascalientes, Mexico (EPSG:32613, UTM zone 13N; the
`[TITLE]` carries `Q_VAR_PROJECTION=EPSG:32613`). Pipes, diameters, demands, elevations, reservoir and tank are invented; not a real utility.

- `demo-town.inp`: the base network (191 junctions).
- `demo-town-portal.inp`: a fuller version with 3 pressure-reducing valves, 3 districts and 8 sensors.
  - `demo-town-portal.json`: its FlowAnalyzer Web project.
  - `demo-town-portal-readings.csv`: one week of invented sensor readings.
  - `demo-town-portal-mapping.csv`: how the sensors map onto the network.
- The derived street database is the network geometry itself (junction coordinates and pipe vertices from OpenStreetMap streets).

## Licence and attribution
Street layout © OpenStreetMap contributors, available under the Open Database License (ODbL) 1.0:
https://opendatacommons.org/licenses/odbl/1-0/ · https://www.openstreetmap.org/copyright

The networks and the derived database in this repository are made available under the same ODbL 1.0 (see `LICENSE.md`).
Any app or document that uses a network from here must show: «Street layout © OpenStreetMap contributors (ODbL)».
Ground levels: SRTM 30 m, via OpenTopoData.
