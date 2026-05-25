"""
db_to_parquet.py

Reads 20 rows from SalesLT.Product,
converts them to a Parquet file, and uploads to the 'sample_data'
container in Azure Blob Storage using managed identity / DefaultAzureCredential.

Environment variables (set as App Service app settings or locally):
    SQL_SERVER          - e.g. sql-server-jn.database.windows.net
    SQL_DATABASE        - e.g. alfa-db
    SQL_USERNAME        - e.g. alfa_read_user
    SQL_PASSWORD        - SQL user password
  AZURE_STORAGE_ACCOUNT - e.g. stappalfbx
  AZURE_CLIENT_ID     - client ID of the user-assigned managed identity (optional locally)
"""

import io
import json
import os
import datetime
import time
import pyodbc
import pandas as pd
from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.storage.blob import BlobServiceClient

# ---------------------------------------------------------------------------
# Configuration (from environment variables)
# ---------------------------------------------------------------------------
SQL_SERVER        = os.environ.get("SQL_SERVER", "sql-server-jn.database.windows.net")
SQL_DATABASE      = os.environ.get("SQL_DATABASE", "alfa-db")
SQL_USERNAME      = os.environ.get("SQL_USERNAME", "alfa_read_user")
SQL_PASSWORD      = os.environ.get("SQL_PASSWORD")

STORAGE_ACCOUNT   = os.environ.get("AZURE_STORAGE_ACCOUNT", "stappalfbx")
OUTPUT_CONTAINER_NAME    = "output"
BLOB_NAME_PREFIX  = "sample-data"

CONFIG_CONTAINER_NAME = "app-config"
CONFIG_BLOB_NAME  = os.environ.get("APP_CONFIG_BLOB_NAME", "query-config.json")
SQL_QUERY_CONFIG_KEY = os.environ.get("SQL_QUERY_CONFIG_KEY", "sql_query")
DEFAULT_SQL_QUERY = "SELECT TOP 20 * FROM SalesLT.Product"

# ---------------------------------------------------------------------------
# Helper: acquire a pyodbc connection using SQL username/password
# ---------------------------------------------------------------------------
def get_sql_connection() -> pyodbc.Connection:
    """Open a pyodbc connection authenticated via SQL username/password."""
    if not SQL_PASSWORD:
        raise ValueError("Set SQL_PASSWORD environment variable before running this pipeline.")

    conn_str = (
        "Driver={ODBC Driver 18 for SQL Server};"
        f"Server=tcp:{SQL_SERVER},1433;"
        f"Database={SQL_DATABASE};"
        f"UID={SQL_USERNAME};"
        f"PWD={SQL_PASSWORD};"
        "Encrypt=yes;"
        "TrustServerCertificate=no;"
        "Connection Timeout=30;"
    )

    last_error = None
    for attempt in range(1, 6):
        try:
            return pyodbc.connect(conn_str)
        except pyodbc.Error as exc:
            last_error = exc
            error_text = str(exc)
            if attempt < 6 and ("28000" in error_text or "Login failed for user" in error_text):
                wait_seconds = attempt * 5
                print(f"SQL login failed on attempt {attempt}/5; retrying in {wait_seconds}s...")
                time.sleep(wait_seconds)
                continue
            raise

    raise last_error


# ---------------------------------------------------------------------------
# Helper: fetch rows into a DataFrame
# ---------------------------------------------------------------------------
def fetch_data(conn: pyodbc.Connection, sql_query: str) -> pd.DataFrame:
    cursor = conn.cursor()
    cursor.execute(sql_query)
    columns = [col[0] for col in cursor.description]
    rows = cursor.fetchall()
    cursor.close()
    return pd.DataFrame.from_records(rows, columns=columns)


def load_sql_query_from_config(credential: DefaultAzureCredential) -> str:
    """Load SQL query from JSON config in Blob Storage, fallback to default query."""
    account_url = f"https://{STORAGE_ACCOUNT}.blob.core.windows.net"
    blob_service = BlobServiceClient(account_url=account_url, credential=credential)

    try:
        container_client = blob_service.get_container_client(CONFIG_CONTAINER_NAME)
        if not container_client.exists():
            print(
                f"Config container '{CONFIG_CONTAINER_NAME}' not found. "
                f"Using default query."
            )
            return DEFAULT_SQL_QUERY

        blob_client = container_client.get_blob_client(CONFIG_BLOB_NAME)
        if not blob_client.exists():
            print(
                f"Config blob '{CONFIG_BLOB_NAME}' not found in '{CONFIG_CONTAINER_NAME}'. "
                f"Using default query."
            )
            return DEFAULT_SQL_QUERY

        raw_bytes = blob_client.download_blob().readall()
        config = json.loads(raw_bytes.decode("utf-8"))

        configured_query = config.get(SQL_QUERY_CONFIG_KEY)
        if isinstance(configured_query, str) and configured_query.strip():
            return configured_query.strip()

        print(
            f"Config key '{SQL_QUERY_CONFIG_KEY}' is missing/empty in '{CONFIG_BLOB_NAME}'. "
            f"Using default query."
        )
        return DEFAULT_SQL_QUERY
    except Exception as exc:
        print(f"Failed to load query config from Blob Storage ({exc}). Using default query.")
        return DEFAULT_SQL_QUERY


# ---------------------------------------------------------------------------
# Helper: convert DataFrame to Parquet bytes
# ---------------------------------------------------------------------------
def to_parquet_bytes(df: pd.DataFrame) -> bytes:
    buffer = io.BytesIO()
    df.to_parquet(buffer, index=False, engine="pyarrow")
    return buffer.getvalue()


# ---------------------------------------------------------------------------
# Helper: upload bytes to blob storage
# ---------------------------------------------------------------------------
def upload_to_blob(credential: DefaultAzureCredential, data: bytes, blob_name: str) -> str:
    account_url = f"https://{STORAGE_ACCOUNT}.blob.core.windows.net"
    blob_service = BlobServiceClient(account_url=account_url, credential=credential)

    container_client = blob_service.get_container_client(OUTPUT_CONTAINER_NAME)
    if not container_client.exists():
        container_client.create_container()
        print(f"Created container '{OUTPUT_CONTAINER_NAME}'.")

    blob_client = container_client.get_blob_client(blob_name)
    blob_client.upload_blob(data, overwrite=True)
    return blob_client.url


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    timestamp = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    blob_name = f"{BLOB_NAME_PREFIX}_{timestamp}.parquet"

    # For user-assigned managed identity on App Service, use ManagedIdentityCredential with client ID.
    # Fall back to DefaultAzureCredential for local development.
    client_id = os.environ.get("AZURE_CLIENT_ID")
    if client_id:
        print(f"Authenticating with ManagedIdentityCredential (client_id={client_id[:8]}...)...")
        credential = ManagedIdentityCredential(client_id=client_id)
    else:
        print(f"Authenticating with DefaultAzureCredential...")
        credential = DefaultAzureCredential()

    sql_query = load_sql_query_from_config(credential)

    print(f"Connecting to {SQL_SERVER} / {SQL_DATABASE}...")
    with get_sql_connection() as conn:
        print(f"Running: {sql_query}")
        df = fetch_data(conn, sql_query)

    print(f"Fetched {len(df)} rows. Columns: {list(df.columns)}")
    print(df.head())

    print("Converting to Parquet...")
    parquet_bytes = to_parquet_bytes(df)
    print(f"Parquet size: {len(parquet_bytes)} bytes")

    print(f"Uploading to blob storage account '{STORAGE_ACCOUNT}', container '{OUTPUT_CONTAINER_NAME}', blob '{blob_name}'...")
    url = upload_to_blob(credential, parquet_bytes, blob_name)
    print(f"Upload complete. Blob URL: {url}")


if __name__ == "__main__":
    main()
