"""
app.py - Flask web application wrapper for the DB-to-Parquet pipeline.

Routes:
  GET  /        Health check / status
  POST /run     Trigger the pipeline: SQL -> parquet -> blob storage
"""

import logging
import os
import traceback

from flask import Flask, jsonify
from db_to_parquet import main as run_pipeline

app = Flask(__name__)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

try:
    from azure.monitor.opentelemetry import configure_azure_monitor

    connection_string = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")
    if connection_string:
        configure_azure_monitor(connection_string=connection_string)
        logger.info("Application Insights telemetry configured.")
    else:
        logger.warning("APPLICATIONINSIGHTS_CONNECTION_STRING is not set. Telemetry disabled.")
except ImportError:
    logger.warning("azure-monitor-opentelemetry package not installed. Telemetry disabled.")
except Exception as exc:
    logger.warning("Failed to initialize Application Insights telemetry: %s", exc)


@app.route("/", methods=["GET"])
def health():
    logger.info("Health endpoint called")
    return jsonify({"status": "ok", "service": "db-to-parquet"}), 200


@app.route("/run", methods=["POST"])
def run():
    logger.info("Pipeline endpoint called")
    try:
        run_pipeline()
        logger.info("Pipeline completed successfully")
        return jsonify({"status": "success", "message": "Pipeline completed successfully."}), 200
    except Exception as exc:
        logger.exception("Pipeline execution failed")
        return jsonify({"status": "error", "message": str(exc), "detail": traceback.format_exc()}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)