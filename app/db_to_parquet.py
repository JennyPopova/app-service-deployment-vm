"""
db_to_parquet.py

Reads 20 rows from SalesLT.Product (Azure SQL, Entra-only auth),
converts them to a Parquet file, and uploads to the 'sample_data'
container in Azure Blob Storage using managed identity / DefaultAzureCredential.

Environment variables (set as App Service app settings or locally):
  AZURE_SQL_SERVER    - e.g. sql-alfbx.database.windows.net
  AZURE_SQL_DATABASE  - e.g. sqldb-adventureworks
  AZURE_STORAGE_ACCOUNT - e.g. stappalfbx
  AZURE_CLIENT_ID     - client ID of the user-assigned managed identity (optional locally)
"""

import io
import os
import struct
import datetime
import time
import pyodbc
import pandas as pd
from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.storage.blob import BlobServiceClient

# ---------------------------------------------------------------------------
# Configuration (from environment variables)
# ---------------------------------------------------------------------------
SQL_SERVER        = os.environ.get("AZURE_SQL_SERVER", "sql-alfbx.database.windows.net")
SQL_DATABASE      = os.environ.get("AZURE_SQL_DATABASE", "sqldb-adventureworks")
STORAGE_ACCOUNT   = os.environ.get("AZURE_STORAGE_ACCOUNT", "stappalfbx")
CONTAINER_NAME    = "output"
BLOB_NAME_PREFIX  = "sample-data"
SQL_QUERY         = "SELECT TOP 20 * FROM SalesLT.Product"

# ---------------------------------------------------------------------------
# Helper: acquire a pyodbc connection using an Azure AD access token
# ---------------------------------------------------------------------------
def get_sql_connection(credential: DefaultAzureCredential) -> pyodbc.Connection:
    """Open a pyodbc connection authenticated via Azure AD token."""
    # Acquire token for Azure SQL
    token_obj = credential.get_token("https://database.windows.net/.default")
    raw_token = token_obj.token.encode("utf-16-le")
    token_struct = struct.pack(f"<I{len(raw_token)}s", len(raw_token), raw_token)

    conn_str = (
        "Driver={ODBC Driver 18 for SQL Server};"
        f"Server=tcp:{SQL_SERVER},1433;"
        f"Database={SQL_DATABASE};"
        "Encrypt=yes;"
        "TrustServerCertificate=no;"
        "Connection Timeout=30;"
    )
    sql_copt_ss_access_token = 1256  # pyodbc constant for SQL_COPT_SS_ACCESS_TOKEN

    last_error = None
    for attempt in range(1, 6):
        try:
            return pyodbc.connect(conn_str, attrs_before={sql_copt_ss_access_token: token_struct})
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
def fetch_data(conn: pyodbc.Connection) -> pd.DataFrame:
    cursor = conn.cursor()
    cursor.execute(SQL_QUERY)
    columns = [col[0] for col in cursor.description]
    rows = cursor.fetchall()
    cursor.close()
    return pd.DataFrame.from_records(rows, columns=columns)


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

    container_client = blob_service.get_container_client(CONTAINER_NAME)
    if not container_client.exists():
        container_client.create_container()
        print(f"Created container '{CONTAINER_NAME}'.")

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

    print(f"Connecting to {SQL_SERVER} / {SQL_DATABASE}...")
    with get_sql_connection(credential) as conn:
        print(f"Running: {SQL_QUERY}")
        df = fetch_data(conn)

    print(f"Fetched {len(df)} rows. Columns: {list(df.columns)}")
    print(df.head())

    print("Converting to Parquet...")
    parquet_bytes = to_parquet_bytes(df)
    print(f"Parquet size: {len(parquet_bytes)} bytes")

    print(f"Uploading to blob storage account '{STORAGE_ACCOUNT}', container '{CONTAINER_NAME}', blob '{blob_name}'...")
    url = upload_to_blob(credential, parquet_bytes, blob_name)
    print(f"Upload complete. Blob URL: {url}")


if __name__ == "__main__":
    main()
