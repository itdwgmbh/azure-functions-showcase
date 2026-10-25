"""Process queued email IDs without keeping a Logic Apps HTTP request open."""

import logging

import azure.functions as func
import mssql_python
from azure.core.exceptions import AzureError

from importer import GraphUnavailable, InvalidWorkbook, import_message

app = func.FunctionApp()
logger = logging.getLogger(__name__)


@app.queue_trigger(
    arg_name="message",
    queue_name="%IMPORT_QUEUE%",
    connection="AzureWebJobsStorage",
)
def import_workbook(message: func.QueueMessage) -> None:
    try:
        message_id = message.get_body().decode("utf-8")
        if not message_id:
            raise ValueError("The queue message contains no email ID.")
        for item in import_message(message_id):
            logger.info(
                "Attachment %s: status=%s rows=%s queue=%s",
                item["contentHash"],
                item["status"],
                item["rowCount"],
                message.id,
            )
    except (mssql_python.Error, AzureError, ValueError, GraphUnavailable) as exc:
        # Fail the invocation so the runtime retries it. Avoid logging SQL data.
        detail = (
            str(exc)
            if isinstance(exc, (InvalidWorkbook, GraphUnavailable))
            else type(exc).__name__
        )
        raise RuntimeError(f"Queue {message.id}: {detail}") from None
