"""Extract: client CRM exports (GCS) -> raw_crm.* in BigQuery.

The client drops a full snapshot of each table into GCS every night, named
crm_<feed>_YYYY-MM-DD.csv. Nothing is ever inserted or deleted between
snapshots -- attributes drift instead -- so the warehouse keeps every snapshot
and reconstructs history from them.

Design notes
------------
State lives in the warehouse, not in a local manifest file. Each run asks the
destination table which snapshot_dates it already holds and loads only the gap.
A run that dies halfway leaves the next run able to work out exactly what is
outstanding, with no cleanup and no state file to drift out of sync.

Every source column is loaded as STRING. The CSVs contain "GBP 76,503.29",
dd/mm/yyyy dates mixed with ISO dates, and empty strings; schema autodetection
guesses wrong and, worse, can guess differently on different files. Keeping the
raw layer byte-faithful means ingestion never fails on a data quality problem --
it surfaces downstream as a failing dbt test instead.

Usage:
    python -m extract.extract_crm                 # sync everything
    python -m extract.extract_crm --feed accounts # one feed only
"""

import argparse
import csv
import datetime as dt
import io
import re
import sys

from google.cloud import bigquery, storage
from google.cloud.exceptions import NotFound

from extract import config

SNAPSHOT_FILENAME = re.compile(r"^crm_(?P<feed>\w+)_(?P<date>\d{4}-\d{2}-\d{2})\.csv$")

# Lineage columns added to every row. snapshot_date is typed (we derive it, so
# it is clean) which lets us cluster on it; source columns stay STRING.
LINEAGE_FIELDS = [
    bigquery.SchemaField("snapshot_date", "DATE", mode="REQUIRED"),
    bigquery.SchemaField("_source_file", "STRING"),
    bigquery.SchemaField("_loaded_at", "TIMESTAMP"),
]


def parse_snapshot_date(object_name: str) -> dt.date:
    """Pull the snapshot date out of a CRM export filename.

    Raises rather than returning None on an unexpected name -- a file we cannot
    date is a file we must not load silently.
    """
    match = SNAPSHOT_FILENAME.match(object_name.rsplit("/", 1)[-1])
    if not match:
        raise ValueError(f"Not a recognised CRM export filename: {object_name!r}")
    return dt.date.fromisoformat(match.group("date"))


def missing_snapshots(available: dict, loaded: set) -> list:
    """Snapshot dates present in the bucket but not yet in BigQuery.

    Pure set logic, kept separate from any I/O so it can be tested directly.
    """
    return sorted(set(available) - set(loaded))


def list_snapshots(gcs: storage.Client, feed: str) -> dict:
    """Map every snapshot date in the bucket to its gs:// URI, for one feed."""
    prefix = f"crm/crm_{feed}_"
    snapshots = {}
    for blob in gcs.list_blobs(config.CRM_BUCKET, prefix=prefix):
        if not blob.name.endswith(".csv"):
            continue
        snapshots[parse_snapshot_date(blob.name)] = f"gs://{config.CRM_BUCKET}/{blob.name}"
    return snapshots


def loaded_snapshots(bq: bigquery.Client, table_id: str) -> set:
    """Snapshot dates already in the destination table.

    Returns an empty set if the table does not exist yet, so the first run
    naturally loads everything.
    """
    try:
        bq.get_table(table_id)
    except NotFound:
        return set()
    rows = bq.query(f"select distinct snapshot_date from `{table_id}`").result()
    return {row.snapshot_date for row in rows}


def read_snapshot(gcs: storage.Client, uri: str, snapshot_date: dt.date) -> tuple:
    """Download one CSV and return (rows, header).

    Values are kept exactly as they appear in the file -- no trimming, no
    casting. That is the staging layer's job.
    """
    _, _, bucket_and_path = uri.partition("gs://")
    bucket_name, _, object_path = bucket_and_path.partition("/")
    blob = gcs.bucket(bucket_name).blob(object_path)
    text = blob.download_as_text()

    reader = csv.DictReader(io.StringIO(text))
    loaded_at = dt.datetime.now(dt.timezone.utc).isoformat()
    rows = [
        {
            **record,
            "snapshot_date": snapshot_date.isoformat(),
            "_source_file": uri,
            "_loaded_at": loaded_at,
        }
        for record in reader
    ]
    return rows, reader.fieldnames


def build_schema(header) -> list:
    """Every source column as STRING, plus the typed lineage columns."""
    return [bigquery.SchemaField(name, "STRING") for name in header] + LINEAGE_FIELDS


def sync_feed(bq: bigquery.Client, gcs: storage.Client, feed: str) -> int:
    """Load any snapshots of one feed that BigQuery does not have yet."""
    table_id = f"{config.PROJECT_ID}.{config.RAW_CRM_DATASET}.{feed}_snapshots"

    available = list_snapshots(gcs, feed)
    already = loaded_snapshots(bq, table_id)
    missing = missing_snapshots(available, already)

    if not missing:
        print(f"  {feed}: up to date ({len(already)} snapshots)")
        return 0

    print(f"  {feed}: {len(missing)} new snapshot(s), {missing[0]} .. {missing[-1]}")

    # One load job per feed per run, not per file: 180 sequential jobs would
    # take half an hour, and the whole feed is only a few MB.
    rows, header = [], None
    for snapshot_date in missing:
        batch, fieldnames = read_snapshot(gcs, available[snapshot_date], snapshot_date)
        if header is None: # takes the first file's header as the canonical schema for the feed, and checks that all subsequent files match it.
            header = fieldnames
        elif fieldnames != header: # encountered a file with a different schema than the first one, which is unexpected and raises an error.
            raise RuntimeError(
                f"{feed}: column drift on {snapshot_date}. "
                f"Expected {header}, found {fieldnames}."
            )
        rows.extend(batch)

    # Clustered on snapshot_date, deliberately not partitioned on it. A BigQuery
    # sandbox forces a 60-day partition expiration on every dataset and will not
    # let you remove it, and every snapshot here is 94-273 days old -- so date
    # partitions would be born already expired and swept away moments after a
    # load job reported success. Clustering gives the same pruning on a feed of
    # a few MB with none of the expiry semantics.
    job_config = bigquery.LoadJobConfig(
        schema=build_schema(header),
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
        clustering_fields=["snapshot_date"],
    )
    job = bq.load_table_from_json(rows, table_id, job_config=job_config)
    job.result()  # raises if the job failed

    # Trust the destination, not the job status. A load that reports success but
    # writes nothing is the one failure mode that would silently produce an
    # empty warehouse, so assert the rows actually landed.
    if job.output_rows != len(rows):
        raise RuntimeError(
            f"{feed}: sent {len(rows):,} rows to {table_id} but BigQuery "
            f"reports {job.output_rows:,} written."
        )
    print(f"  {feed}: loaded {job.output_rows:,} rows into {table_id}")
    return len(missing)


def sync_product_catalogue(bq: bigquery.Client) -> None:
    """Load the product catalogue straight from GCS.

    Not a nightly feed -- one file, replaced wholesale each run. Parquet carries
    its own schema, so no type guessing is needed and nothing has to be
    downloaded locally.
    """
    table_id = f"{config.PROJECT_ID}.{config.RAW_CRM_DATASET}.product_catalogue"
    uri = f"gs://{config.CRM_BUCKET}/{config.PRODUCT_CATALOGUE_OBJECT}"
    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.PARQUET,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    bq.load_table_from_uri(uri, table_id, job_config=job_config).result()
    print(f"  product_catalogue: reloaded from {uri}")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--feed", choices=config.CRM_FEEDS, help="sync a single feed instead of all"
    )
    parser.add_argument(
        "--skip-catalogue", action="store_true", help="do not reload the catalogue"
    )
    args = parser.parse_args(argv)

    bq = bigquery.Client(project=config.PROJECT_ID, location=config.LOCATION)
    # The bucket is publicly readable, so read it anonymously and prove the
    # pipeline does not depend on ambient credentials a reviewer will not have.
    gcs = storage.Client.create_anonymous_client()

    feeds = (args.feed,) if args.feed else config.CRM_FEEDS

    # Print the resolved project explicitly: BQ_PROJECT_ID comes from the
    # environment, so "wrote fine but the table looks empty" is usually "wrote
    # fine, to a different project than the one you are querying".
    print(f"Syncing CRM into {config.PROJECT_ID}.{config.RAW_CRM_DATASET}")
    print(f"  (billing/credentials project: {bq.project})")
    total = sum(sync_feed(bq, gcs, feed) for feed in feeds)

    if not args.skip_catalogue:
        sync_product_catalogue(bq)

    print(f"Done. {total} new snapshot(s) loaded.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
