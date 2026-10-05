# Test fixtures

`snapshot/` is a real snapshot, cut down from a full run's `tmp/snapshot/` on 2026-10-05 to 15 layers, chosen for the cases they exercise:

| Layer | Case |
|---|---|
| `MODIS_Terra_CorrectedReflectance_TrueColor` | A true-color composite: JPEG, daily since 2000, ongoing |
| `GHRSST_L4_MUR_Sea_Surface_Temperature` | A measurement drawn through a color map, with a DOI |
| `TEMPO_L3_NO2_Vertical_Column_Troposphere` | Sub-daily, so its capabilities list only the latest 100 periods and its start comes from `domains.jsonl`; regional, from CMR's polygons |
| `GPW_Population_Density_2020` | No time dimension; licensed CC BY 4.0 |
| `GRanD_Dams` | Vector, so WMS only |
| `MEaSUREs_Ice_Velocity_Greenland` | Published only in the Arctic projection |
| `SEAWIFS_ORBVIEW-2_GAC_Chlorophyll_a`, `SEAWIFS_ORBVIEW-2_MLAC_Chlorophyll_a` | Two layers with the same title; MLAC isn't in Worldview |
| `DISCOVER-AQ_TX_P3B_Ozone` | Vector, aircraft-borne, not in Worldview, so its description is CMR's abstract |
| `OMPS_NOAA20_NadirMapper_AerosolIndex_360` | Called ongoing by GIBS, but without imagery since May 2025 |
| `MISR_Aerosol_Optical_Depth_Avg_Green_Monthly` | Every collection it links is gone from CMR |
| `LIS_Very_High_Resolution_Lightning_Full_Climatology_LIS_Mean_Flash_Rate` | A single date, the first of a year |
| `OrbitTracks_Aqua_Ascending` | A utility layer, which gets no record |
| `CERES_Combined_TOA_Longwave_Flux_All_Sky_Daily` | A tile template asking for a date its capabilities don't offer, so no record |
| `Graticule_Extended` | No layer metadata, so no record |

The files:
- `capabilities-*.xml`: each projection's capabilities, with only these layers' `<Layer>` elements, and without the tile matrix sets and operations, which the harvester doesn't read.
- `layer-metadata.jsonl`: `{id, metadata}` for each layer GIBS documents.
- `domains.jsonl`: `{id, start}` for the truncated layer.
- `collections.jsonl`: `{concept_id, umm}` for each linked collection CMR has.
- `worldview/`: Worldview's configuration for these layers, in the snapshot's layout, which flattens the repository's: their layer files in `layers/` and descriptions in `descriptions/`, the measurements listing them in `measurements/` (cut to just these layers), and the science disciplines in `categories/` and `redirects.json` whole.
