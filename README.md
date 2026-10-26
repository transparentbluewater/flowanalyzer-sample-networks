# FlowAnalyzer sample networks

Sample water distribution networks (EPANET `.inp`) for demonstrations, tests and tutorials of the FlowAnalyzer apps.
They contain **no data from any real utility or client**: every hydraulic asset is invented.

## Tiradentes (synthetic)
`tiradentes/tiradentes-synthetic.inp`: a synthetic network laid along the real streets of the town centre of Tiradentes,
Minas Gerais, Brazil. Sources, pipes, diameters, demands and patterns are invented; it is **not** the town's real water system.

- Coordinates in WGS 84 / UTM zone 23S (EPSG:32723), metres. The `[TITLE]` carries `Q_VAR_PROJECTION=EPSG:32723`, so apps that
  read that line open it in place on a map.
- Two pressure zones with PRVs, one tank, one reservoir, 96 h extended period. Ground levels approximate (SRTM 30 m).
- `tiradentes/data/tiradentes_streets.json`: the derived street database it is built from (OpenStreetMap streets, SRTM ground levels).
- `tiradentes/tool/generate_tiradentes_sample.dart`: the generator, kept for reproducibility. It runs inside the FlowAnalyzer mobile
  app's source tree (it uses the app's UTM projection); the header explains both stages.
- sha256 of the `.inp`: `c31d0d3b44bc0248e779368531496b6896877584fe88e817e3f469870fbc7180`.

## Licence and attribution
Street layout © OpenStreetMap contributors, available under the Open Database License (ODbL) 1.0:
https://opendatacommons.org/licenses/odbl/1-0/ · https://www.openstreetmap.org/copyright

The networks and the derived database in this repository are made available under the same ODbL 1.0 (see `LICENSE.md`).
Any app or document that uses a network from here must show: «Street layout © OpenStreetMap contributors (ODbL)».
Ground levels: SRTM 30 m, via OpenTopoData.
