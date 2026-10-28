"""Nodara delta-sink · Debezium CDC (Kafka) → Delta Lake bronze on MinIO → silver views in Trino.

Every captured S/4HANA table becomes an append-only Delta changelog at
s3://lakehouse/bronze/<table>, registered in Trino (lakehouse.bronze.<table>) and in
Unity Catalog (nodara.bronze.<table>). Kafka offsets are committed only after the
Delta commit succeeds → at-least-once delivery. The silver layer (lakehouse.silver.<table>)
is a Trino view with the current state of the SAP table: latest image per primary key
(taken from the Debezium message key), deletes removed, so duplicates never reach analytics.
Column types are derived from the Debezium schema, so new tables need no code.
"""
from __future__ import annotations

import base64
import json
import logging
import os
import signal
import time
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

import httpx
import pyarrow as pa
import trino
from confluent_kafka import Consumer, KafkaError
from deltalake import write_deltalake

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"),
                    format="%(asctime)s %(levelname)s [delta-sink] %(message)s")
log = logging.getLogger("delta-sink")
logging.getLogger("httpx").setLevel(logging.WARNING)

KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "kafka:9092")
TOPIC_PATTERN = os.getenv("TOPIC_PATTERN", r"^s4hana\.sap\..+")
GROUP_ID = os.getenv("GROUP_ID", "nodara-delta-sink")
BUCKET = os.getenv("LAKEHOUSE_BUCKET", "lakehouse")
LAYER = "bronze"
SILVER = "silver"
FLUSH_INTERVAL_S = float(os.getenv("FLUSH_INTERVAL_S", "5"))
MAX_BATCH_ROWS = int(os.getenv("MAX_BATCH_ROWS", "10000"))
TRINO_HOST = os.getenv("TRINO_HOST", "trino")
TRINO_PORT = int(os.getenv("TRINO_PORT", "8080"))
TRINO_CATALOG = os.getenv("TRINO_CATALOG", "lakehouse")
UC_API = os.getenv("UC_API", "http://unity-catalog:8080/api/2.1/unity-catalog")
UC_CATALOG = os.getenv("UC_CATALOG", "nodara")
HEARTBEAT = Path("/tmp/heartbeat")

STORAGE_OPTIONS = {
    "AWS_ENDPOINT_URL": os.environ["S3_ENDPOINT"],
    "AWS_ACCESS_KEY_ID": os.environ["S3_ACCESS_KEY"],
    "AWS_SECRET_ACCESS_KEY": os.environ["S3_SECRET_KEY"],
    "AWS_REGION": os.getenv("S3_REGION", "us-east-1"),
    "AWS_ALLOW_HTTP": "true",
    "AWS_S3_ALLOW_UNSAFE_RENAME": "true",  # exactly one writer per table → no lock service
}

EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
EPOCH_DATE = date(1970, 1, 1)

# ── Debezium JsonConverter schema → Arrow ────────────────────────────────────
_PRIMITIVES = {"int8": pa.int8(), "int16": pa.int16(), "int32": pa.int32(), "int64": pa.int64(),
               "float": pa.float32(), "double": pa.float64(), "boolean": pa.bool_(),
               "string": pa.string(), "bytes": pa.binary()}
_DECIMAL = "org.apache.kafka.connect.data.Decimal"
_DATE = {"io.debezium.time.Date", "org.apache.kafka.connect.data.Date"}
_TIMESTAMP_UNIT = {"io.debezium.time.Timestamp": "ms", "org.apache.kafka.connect.data.Timestamp": "ms",
                   "io.debezium.time.MicroTimestamp": "us", "io.debezium.time.NanoTimestamp": "ns"}
_TIME_UNIT = {"io.debezium.time.Time": "ms", "org.apache.kafka.connect.data.Time": "ms",
              "io.debezium.time.MicroTime": "us", "io.debezium.time.NanoTime": "ns"}
_ZONED_TIMESTAMP = "io.debezium.time.ZonedTimestamp"

UTC_MICROS = pa.timestamp("us", tz="UTC")
META_FIELDS = [
    pa.field("_cdc_op", pa.string()),        # c insert · u update · d delete · r snapshot read
    pa.field("_source_ts", UTC_MICROS),      # commit time in S/4HANA
    pa.field("_source_lsn", pa.int64()),
    pa.field("_source_txid", pa.int64()),
    pa.field("_kafka_offset", pa.int64()),
    pa.field("_ingested_at", UTC_MICROS),    # Delta commit time → freshness = _ingested_at - _source_ts
]
META_NAMES = {f.name for f in META_FIELDS}


def _to_micros(value: int, unit: str) -> int:
    return value * 1000 if unit == "ms" else value // 1000 if unit == "ns" else value


def arrow_type(field: dict) -> pa.DataType:
    name = field.get("name")
    if name == _DECIMAL:
        params = field["parameters"]
        return pa.decimal128(int(params.get("connect.decimal.precision", 38)), int(params["scale"]))
    if name in _DATE:
        return pa.date32()
    if name in _TIMESTAMP_UNIT or name == _ZONED_TIMESTAMP:
        return UTC_MICROS
    if name in _TIME_UNIT:
        return pa.string()  # Delta Lake has no TIME type → ISO 'HH:MM:SS'
    return _PRIMITIVES.get(field["type"], pa.string())


def convert(value, field: dict):
    if value is None:
        return None
    name = field.get("name")
    if name == _DECIMAL:
        unscaled = int.from_bytes(base64.b64decode(value), "big", signed=True)
        return Decimal(unscaled).scaleb(-int(field["parameters"]["scale"]))
    if name in _DATE:
        return EPOCH_DATE + timedelta(days=value)
    if name in _TIMESTAMP_UNIT:
        return EPOCH + timedelta(microseconds=_to_micros(value, _TIMESTAMP_UNIT[name]))
    if name == _ZONED_TIMESTAMP:
        return datetime.fromisoformat(value)
    if name in _TIME_UNIT:
        return (datetime.min + timedelta(microseconds=_to_micros(value, _TIME_UNIT[name]))).time().isoformat()
    if field["type"] == "bytes":
        return base64.b64decode(value)
    if field["type"] in ("struct", "array", "map"):
        return json.dumps(value)
    return value


def row_fields(envelope_schema: dict) -> list[dict]:
    return next(f["fields"] for f in envelope_schema["fields"] if f["field"] in ("after", "before"))


# ── Catalog registration (query engine + governance) ─────────────────────────
_UC_TYPES = [(pa.types.is_int8, "BYTE", "tinyint", "byte"), (pa.types.is_int16, "SHORT", "smallint", "short"),
             (pa.types.is_int32, "INT", "int", "integer"), (pa.types.is_int64, "LONG", "bigint", "long"),
             (pa.types.is_float32, "FLOAT", "float", "float"), (pa.types.is_float64, "DOUBLE", "double", "double"),
             (pa.types.is_boolean, "BOOLEAN", "boolean", "boolean"), (pa.types.is_date32, "DATE", "date", "date"),
             (pa.types.is_timestamp, "TIMESTAMP", "timestamp", "timestamp"),
             (pa.types.is_binary, "BINARY", "binary", "binary")]


def uc_columns(schema: pa.Schema) -> list[dict]:
    columns = []
    for position, field in enumerate(schema):
        type_name, type_text, spark_type, precision, scale = "STRING", "string", "string", 0, 0
        if pa.types.is_decimal(field.type):
            type_text = spark_type = f"decimal({field.type.precision},{field.type.scale})"
            type_name, precision, scale = "DECIMAL", field.type.precision, field.type.scale
        else:
            for predicate, uc_name, text, spark in _UC_TYPES:
                if predicate(field.type):
                    type_name, type_text, spark_type = uc_name, text, spark
                    break
        columns.append({
            "name": field.name, "type_name": type_name, "type_text": type_text,
            "type_json": json.dumps({"name": field.name, "type": spark_type, "nullable": True, "metadata": {}}),
            "type_precision": precision, "type_scale": scale, "position": position, "nullable": True,
        })
    return columns


class Catalogs:
    """Registers bronze tables in Trino (SQL access) and Unity Catalog (governance)."""

    def __init__(self) -> None:
        self.in_trino: set[str] = set()
        self.in_uc: set[str] = set()
        self.silver: dict[str, tuple] = {}  # table → (columns, key) the current silver view was built with
        self.uc = httpx.Client(base_url=UC_API, timeout=10)

    def _trino(self, sql: str) -> list:
        with trino.dbapi.connect(host=TRINO_HOST, port=TRINO_PORT, user="delta-sink",
                                 catalog=TRINO_CATALOG, source="nodara-delta-sink") as conn:
            cursor = conn.cursor()
            cursor.execute(sql)
            return cursor.fetchall()

    def _uc_create(self, path: str, body: dict) -> None:
        response = self.uc.post(path, json=body)
        if response.is_success:
            return
        # UC answers 400 + *_ALREADY_EXISTS for duplicates (idempotent re-runs after restarts)
        if response.headers.get("content-type", "").startswith("application/json") and \
                response.json().get("error_code", "").endswith("ALREADY_EXISTS"):
            return
        raise RuntimeError(f"Unity Catalog {path} → {response.status_code}: {response.text[:300]}")

    def bootstrap(self) -> None:
        for layer in (LAYER, SILVER):
            self._trino(f"CREATE SCHEMA IF NOT EXISTS {TRINO_CATALOG}.{layer} "
                        f"WITH (location = 's3://{BUCKET}/{layer}/')")
        self._uc_create("/catalogs", {"name": UC_CATALOG,
                                      "comment": "Nodara Rolling Forecast lakehouse (MinIO + Delta Lake)"})
        self._uc_create("/schemas", {"name": LAYER, "catalog_name": UC_CATALOG,
                                     "comment": "Raw CDC changelog from SAP S/4HANA (Debezium)"})
        # Restarts must not re-register: load what both catalogs already know.
        self.in_trino = {row[0] for row in self._trino(
            f"SELECT table_name FROM {TRINO_CATALOG}.information_schema.tables WHERE table_schema = '{LAYER}'")}
        listing = self.uc.get("/tables", params={"catalog_name": UC_CATALOG, "schema_name": LAYER})
        listing.raise_for_status()
        self.in_uc = {t["name"] for t in listing.json().get("tables", [])}

    def register(self, table: str, schema: pa.Schema, uri: str) -> None:
        if table not in self.in_trino:
            try:
                self._trino(f"CALL {TRINO_CATALOG}.system.register_table(schema_name => '{LAYER}', "
                            f"table_name => '{table}', table_location => '{uri}')")
            except trino.exceptions.TrinoUserError as exc:
                if exc.error_name != "ALREADY_EXISTS":
                    raise
            self.in_trino.add(table)
            log.info("registered in Trino → %s.%s.%s", TRINO_CATALOG, LAYER, table)
        if table not in self.in_uc:
            try:
                self._uc_create("/tables", {
                    "name": table, "catalog_name": UC_CATALOG, "schema_name": LAYER,
                    "table_type": "EXTERNAL", "data_source_format": "DELTA", "storage_location": uri,
                    "columns": uc_columns(schema),
                    "comment": f"CDC changelog of SAP S/4HANA table {table.upper()} (Debezium → Delta Lake)",
                    "properties": {"source_system": "S4HANA", "ingestion": "debezium-cdc", "layer": LAYER},
                })
                self.in_uc.add(table)
                log.info("registered in Unity Catalog → %s.%s.%s", UC_CATALOG, LAYER, table)
            except (httpx.HTTPError, RuntimeError) as exc:  # governance metadata must not stop ingestion
                log.warning("Unity Catalog registration of %s deferred: %s", table, exc)

    def publish_silver(self, table: str, schema: pa.Schema, key: list[str]) -> None:
        """(Re)creates lakehouse.silver.<table> when the bronze columns or the primary key change."""
        columns = [f.name for f in schema if f.name not in META_NAMES] + ["_source_ts", "_ingested_at"]
        if self.silver.get(table) == (columns, key):
            return
        select = ", ".join(f'"{c}"' for c in columns)
        partition = ", ".join(f'"{k}"' for k in key)
        try:
            self._trino(
                f"CREATE OR REPLACE VIEW {TRINO_CATALOG}.{SILVER}.{table} COMMENT 'Current state of SAP table "
                f"{table.upper()}: latest CDC image per primary key, deletes removed' AS "
                f"SELECT {select} FROM (SELECT b.*, row_number() OVER (PARTITION BY {partition} "
                f"ORDER BY _source_lsn DESC, _kafka_offset DESC) AS _rn FROM {TRINO_CATALOG}.{LAYER}.{table} b) "
                f"WHERE _rn = 1 AND _cdc_op <> 'd'")
        except trino.exceptions.TrinoQueryError as exc:  # retried on the next batch; bronze keeps flowing
            log.error("silver view %s not created: %s", table, exc)
            return
        self.silver[table] = (columns, key)
        log.info("silver view ready → %s.%s.%s (key: %s)", TRINO_CATALOG, SILVER, table, ", ".join(key))


# ── Pipeline ─────────────────────────────────────────────────────────────────
class Batch:
    def __init__(self) -> None:
        self.rows: dict[str, list[dict]] = {}
        self.schemas: dict[str, pa.Schema] = {}
        self.keys: dict[str, list[str]] = {}  # primary key per table, from the Debezium key schema

    def __len__(self) -> int:
        return sum(len(rows) for rows in self.rows.values())

    def add(self, msg) -> None:
        if msg.value() is None:  # tombstone
            return
        event = json.loads(msg.value())
        payload = event["payload"]
        op = payload["op"]
        if op not in ("c", "u", "d", "r"):  # skip truncate / logical messages
            return
        image = payload["before"] if op == "d" else payload["after"]
        if image is None:
            return
        fields = row_fields(event["schema"])
        table = msg.topic().rsplit(".", 1)[-1]
        if table not in self.keys and msg.key():
            key = json.loads(msg.key())
            self.keys[table] = ([f["field"] for f in key["schema"]["fields"]] if "schema" in key
                                else list(key))
        source = payload["source"]
        source_micros = source.get("ts_us") or source["ts_ms"] * 1000
        row = {f["field"]: convert(image.get(f["field"]), f) for f in fields}
        row.update(_cdc_op=op, _source_ts=EPOCH + timedelta(microseconds=source_micros),
                   _source_lsn=source.get("lsn"), _source_txid=source.get("txId"),
                   _kafka_offset=msg.offset(), _ingested_at=None)
        self.rows.setdefault(table, []).append(row)
        self.schemas[table] = pa.schema([pa.field(f["field"], arrow_type(f)) for f in fields] + META_FIELDS)

    def flush(self, consumer: Consumer, catalogs: Catalogs) -> None:
        if not len(self):
            return
        committed_at = datetime.now(timezone.utc)
        for table, rows in self.rows.items():
            for row in rows:
                row["_ingested_at"] = committed_at
            uri = f"s3://{BUCKET}/{LAYER}/{table}"
            data = pa.Table.from_pylist(rows, schema=self.schemas[table])
            write_deltalake(uri, data, mode="append", schema_mode="merge", storage_options=STORAGE_OPTIONS)
            lag = (committed_at - max(r["_source_ts"] for r in rows)).total_seconds()
            log.info("committed %d rows → %s.%s (freshness %.2fs)", len(rows), LAYER, table, lag)
            catalogs.register(table, self.schemas[table], uri)
            if self.keys.get(table):
                catalogs.publish_silver(table, self.schemas[table], self.keys[table])
        consumer.commit(asynchronous=False)
        self.rows.clear()


def retry(action, what: str, attempts: int = 30, delay_s: float = 2.0) -> None:
    for attempt in range(1, attempts + 1):
        try:
            return action()
        except Exception as exc:  # dependencies may still be warming up
            if attempt == attempts:
                raise
            log.info("waiting for %s (%s)", what, exc)
            time.sleep(delay_s)


def main() -> None:
    catalogs = Catalogs()
    retry(catalogs.bootstrap, "Trino + Unity Catalog")
    consumer = Consumer({
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "group.id": GROUP_ID,
        "enable.auto.commit": False,
        "auto.offset.reset": "earliest",
        "topic.metadata.refresh.interval.ms": 10000,  # pick up new CDC topics quickly
    })
    consumer.subscribe([TOPIC_PATTERN])
    log.info("subscribed to %s → s3://%s/%s", TOPIC_PATTERN, BUCKET, LAYER)

    running = True

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    batch, last_flush = Batch(), time.monotonic()
    while running:
        msg = consumer.poll(1.0)
        HEARTBEAT.touch()
        if msg is not None:
            if msg.error():
                if msg.error().code() == KafkaError.UNKNOWN_TOPIC_OR_PART:
                    log.info("waiting for CDC topics (Debezium snapshot not started yet)")
                elif msg.error().code() != KafkaError._PARTITION_EOF:
                    log.warning("kafka: %s", msg.error())
            else:
                batch.add(msg)
        if len(batch) >= MAX_BATCH_ROWS or time.monotonic() - last_flush >= FLUSH_INTERVAL_S:
            batch.flush(consumer, catalogs)
            last_flush = time.monotonic()

    batch.flush(consumer, catalogs)
    consumer.close()
    log.info("stopped")


if __name__ == "__main__":
    main()
