"""
app.py - Flask web application wrapper for the DB-to-Parquet pipeline.

Routes:
  GET  /        Health check / status
  POST /run     Trigger the pipeline: SQL -> parquet -> blob storage
"""

import traceback
from flask import Flask, jsonify
from db_to_parquet import main as run_pipeline

app = Flask(__name__)


@app.route("/", methods=["GET"])
def health():
    return jsonify({"status": "ok", "service": "db-to-parquet"}), 200


@app.route("/run", methods=["POST"])
def run():
    try:
        run_pipeline()
        return jsonify({"status": "success", "message": "Pipeline completed successfully."}), 200
    except Exception as exc:
        return jsonify({"status": "error", "message": str(exc), "detail": traceback.format_exc()}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)