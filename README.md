# gov.nasa.gibs

This repository contains [OpenGeoMetadata Aardvark](https://opengeometadata.org/ogm-aardvark/) records for the visualization layers of NASA's [Global Imagery Browse Services](https://nasa-gibs.github.io/gibs-api-docs/) (GIBS): imagery of NASA's Earth science observations, most of it updated daily. There is one record per layer, plus a collection record.

The records are generated from what NASA publishes about the layers: GIBS's own service descriptions and layer metadata, the configuration of [Worldview](https://worldview.earthdata.nasa.gov/), NASA's browser for GIBS, and the [Common Metadata Repository](https://cmr.earthdata.nasa.gov/) (CMR) entries for the data the layers are made from. This repository is not an official NASA product.

This metadata is provided under the [CC0 v1.0 License](LICENSE), which allows for free use and redistribution without restrictions. NASA promotes the full and open sharing of its imagery, and GIBS asks that anyone using it include an acknowledgement, which every record carries; a few layers carry their data's own license as well.

## File Structure

```
metadata-aardvark/
  gibs/
    nasa-gibs.json                                              the collection record
    modis/
      nasa-gibs-modis_terra_correctedreflectance_truecolor.json one record per layer, named by its id
      ...
withdrawn.json                                                  records that have left the repository
```

Each record's id is `nasa-gibs-` followed by its layer's GIBS identifier, lowercased, with the dots in a few identifiers made hyphens: `MODIS_Terra_CorrectedReflectance_TrueColor` is `nasa-gibs-modis_terra_correctedreflectance_truecolor`. Records are grouped in directories by the first word of the identifier, which keeps every directory under GitHub's 1,000-entry listing limit. A record's path follows from its id.

## Metadata

- **Version:** OGM Aardvark, with no custom fields.
- **Updates:** a GitHub Actions workflow rebuilds every record daily. Files only change when what NASA says about a layer does, so an unchanged GIBS produces no commit. Ongoing layers gain imagery every day, but their records don't change with it; see [Dates](#dates).
- **Validation:** the tests in `test/` run before every harvest.

### Sources

The harvester reads five things on each run:
- **GIBS's capabilities:** the WMTS capabilities document of each of GIBS's four projections, from its "best available" endpoints, which merge each layer's near-real-time and standard versions. They say which layers exist, and give each one's format, tile grid, time dimension and tile URLs.
- **GIBS's layer metadata:** a [JSON document](https://gibs.earthdata.nasa.gov/layer-metadata/v1.0/) per layer, giving its title and subtitle, the measurement it shows, its period, whether it's ongoing, and the CMR collections it's made from. Worldview's layer list is built from these. There's no description among them.
- **GIBS's domains:** the capabilities list only the latest 100 periods of a layer's time dimension, which cuts short the geostationary and TEMPO layers, whose observations come every 10 minutes to an hour. Their DescribeDomains documents give where they really start.
- **Worldview's configuration:** the layer descriptions Worldview shows, its overrides for some titles, the measurements and science disciplines it files layers under, and redirects for renamed layers. It comes from a sparse clone of [Worldview's repository](https://github.com/nasa-gibs/worldview) at its latest release, a few seconds and 15 MB. The deployed site's combined configuration would do as well, but it's always sent Brotli-compressed, which Ruby can't decode.
- **CMR:** the [collections](https://cmr.earthdata.nasa.gov/search/collections.umm_json) the layers are made from, for their titles, DOIs, citations, platforms, keywords, extents and use constraints.

What it fetched is saved in `tmp/snapshot/`.

### Layers

Every layer in GIBS's capabilities gets a record, except:
- **Utility layers**, which help read other layers rather than show anything themselves: orbit tracks, coastlines, borders, place labels, land masks, graticules and no-data masks (91 in October 2026). Some of the reference layers are derived from OpenStreetMap.
- **Layers whose tiles can't be requested:** their capabilities give a tile URL that asks for a date but no dates to ask for, and GIBS answers every tile with a 404 (23). They're mostly layers GIBS has announced but not yet filled.
- **Layers GIBS doesn't document** with layer metadata (4).

### Extents

Every layer's capabilities claim the whole globe, even TEMPO's, which covers North America. Extents come instead from the bounding rectangles and polygons of the CMR collections a layer is made from, combined across the antimeridian where that's narrower. An extent covering more than 90% of the globe counts as the globe, and a layer published only in a polar projection, without collections to go on, gets its projection's bounding box. About 150 layers get a regional extent. Global layers have no centroid.

### Previews

| Layers | References |
|---|---|
| Raster, in Web Mercator | XYZ tiles, WMTS and WMS |
| Vector | WMS only, from GIBS's Geographic endpoint. GIBS has no Web Mercator vector tiles, and its documentation says its Web Mercator WMS doesn't serve vector layers either; the Geographic WMS draws them as images for the same Web Mercator requests. |
| Published only in polar projections | None: no Web Mercator viewer can draw them |

Every record also links to Worldview (`http://schema.org/url`), with the layer on, under Worldview's coastlines unless it's a picture of the Earth already, for every layer Worldview shows; and to a thumbnail of the latest imagery from GIBS's WMS (`http://schema.org/thumbnailUrl`). Neither URL carries a date, so they never change.

The XYZ template asks for GIBS's default date, which is the latest imagery, as do the WMTS and WMS previews. For a near-real-time daily layer that's the current UTC day, which is partly filled in until its data arrive.

## Withdrawn Records

When a record leaves the repository, it is deleted and logged in `withdrawn.json`.

- **Superseded:** GIBS renames layers now and then, 20 at once early in 2026. If Worldview redirects the old identifier to a layer with a record, or exactly one record created in the same run has the old record's title, the entry's reason is `superseded`, with `is_replaced_by` naming it.
- **Quality:** if GIBS still lists the layer but its tiles can no longer be requested, or it no longer has layer metadata, the reason is `quality`.
- **Upstream-removed:** otherwise, the reason is `upstream-removed`.
- **Republished:** entries are only removed when their layer comes back.

The harvester stops without changing anything when:
- a projection's capabilities list no layers;
- GIBS has no layer metadata for more than 5% of its layers, or CMR has fewer than half the collections GIBS links;
- Worldview's repository can't be cloned or its configuration has no layers;
- two layers would get the same record id;
- the run would remove more than 5% of all records. Set `FORCE=1` if this is intentional.

## Running the Harvester

The harvester needs Ruby 4.0, whose standard library and bundled gems have everything it uses, and `git`.

```bash
ruby harvester.rb
```

These environment variables change how it runs:

- `SOURCE=tmp/snapshot` uses a previous run's snapshot instead of fetching anything.
- `DRY_RUN=1` reports what would change without writing anything.
- `FORCE=1` allows a run that would withdraw more than 5% of the records.

To run the tests:

```bash
for test in test/*_test.rb; do ruby "$test"; done
```

## How to Contribute

For problems with the records, open an issue in this repository. Every record is regenerated daily, so edits to the files would be overwritten:
- **How fields are mapped:** change `mapper.rb`, or `layer.rb` for which layers get records and how their dates and extents are worked out.
- **How descriptions are converted:** change `description.rb`.
- **The data itself:** titles and descriptions are NASA's, in GIBS's layer metadata and Worldview's configuration; the collections' metadata is in CMR. Corrections have to be made by NASA.
