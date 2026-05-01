# Project Charter — acd

## Question

For each building in Vienna, which Area Climate Design (ACD) zone (if any) does it
fall under, and what is the resulting legal heating mandate?

## Deliverable

A reproducible R package that:
1. Fetches Vienna's two open-data sources (Energieraumpläne zones + Gebäudeinformation buildings) from data.wien.gv.at WFS, pinned to a single snapshot date.
2. Joins them spatially with a 6-state diagnostic `link_status` enum that distinguishes legitimate "no zone applies" cases from data-quality failures.
3. Renders an interactive Quarto dashboard showing each source individually, the join, every missing-link case, and worked/failed example stories.

## "Done" looks like

- Dashboard renders against real WFS data (smoke-tested, not synthetic)
- All 6 `link_status` values populated and shown on dedicated tabs
- At least 2 worked stories + 3 failed stories, each with real building IDs
- Snapshot Parquet committed to `inst/extdata/`
- Repo public on GitHub with deployed gh-pages dashboard

## Audience

Self (proof-of-concept). Future users: anyone analysing Vienna heating policy at the building level.

## Timeline

POC end-state: this session or next. Two-district focus + Austria extension: deferred.

## Out of scope (explicitly NOT doing)

- Indoor specs (boiler age, energy bills, EPCs from ZEUS) — privacy-restricted
- Address geocoding fallback (we use spatial join only)
- Area-weighted overlap for straddle cases (centroid join sufficient for POC)
- Multi-zone list-column (single primary zone per building)
- Time series of zone changes (single snapshot only)
- All-Austria coverage (Vienna only; sources for extension documented in CHANGELOG)
- Deployment to anything other than GitHub Pages
- Hugging Face Datasets upload (data <100 MB, doesn't warrant it yet)

## Scope-creep tripwires

If any of these come up, **stop and file a separate issue** rather than expand the POC:
- "Let's also add district X..."
- "Could we time-series this?"
- "Maybe pull Linz / Graz data too?"
- "While we're here, fit a model of zone designation likelihood..."
