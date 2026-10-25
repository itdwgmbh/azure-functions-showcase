"""Deploy the showcase and initialize SQL using the signed-in Azure CLI user."""

import argparse
import ipaddress
import json
import os
import re
import subprocess
import sys
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from urllib.request import urlopen

import mssql_python
from azure.data.tables import TableClient
from azure.identity import AzureCliCredential
from azure.storage.queue import QueueClient

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from importer import connect_sql


def az(*arguments):
    result = subprocess.run(
        ["az", *arguments, "--only-show-errors", "--output", "json"],
        check=True,
        text=True,
        capture_output=True,
    )
    return json.loads(result.stdout) if result.stdout.strip() else None


def deployment_outputs(group):
    result = az(
        "deployment", "group", "show", "--resource-group", group, "--name", "showcase"
    )
    return {key: item["value"] for key, item in result["properties"]["outputs"].items()}


@contextmanager
def sql_access(group, outputs):
    """Open only this operator's public IPv4 address, then remove the rule."""
    with urlopen("https://api.ipify.org", timeout=15) as result:
        address = str(ipaddress.IPv4Address(result.read().decode().strip()))
    rule = f"setup-{uuid.uuid4().hex[:12]}"
    server = outputs["sqlServerName"]
    az(
        "sql",
        "server",
        "firewall-rule",
        "create",
        "--resource-group",
        group,
        "--server",
        server,
        "--name",
        rule,
        "--start-ip-address",
        address,
        "--end-ip-address",
        address,
    )
    os.environ["SQL_SERVER"] = outputs["sqlServerFqdn"]
    os.environ["SQL_DATABASE"] = outputs["sqlDatabaseName"]
    try:
        yield
    finally:
        az(
            "sql",
            "server",
            "firewall-rule",
            "delete",
            "--resource-group",
            group,
            "--server",
            server,
            "--name",
            rule,
        )


def bootstrap_sql(outputs):
    for attempt in range(6):
        try:
            connection = connect_sql(local=True)
            break
        except mssql_python.Error:
            if attempt == 5:
                raise
            print("Waiting for SQL administrator/firewall propagation...", flush=True)
            time.sleep(10)
    with connection:
        cursor = connection.cursor()
        sql = (ROOT / "infra/schema.sql").read_text()
        for batch in re.split(r"^GO\s*$", sql, flags=re.MULTILINE | re.IGNORECASE):
            if batch.strip():
                cursor.execute(batch)
        # SID + TYPE avoids granting Directory Readers permissions to the SQL server.
        # For service principals the SID is the application (client) ID.
        sid = uuid.UUID(outputs["functionClientId"]).bytes_le
        cursor.execute(
            "SELECT sid FROM sys.database_principals WHERE name = N'workbook_importer'"
        )
        existing = cursor.fetchone()
        if existing and bytes(existing[0]) != sid:
            raise RuntimeError(
                "SQL user workbook_importer belongs to a different identity."
            )
        if not existing:
            cursor.execute(
                f"CREATE USER [workbook_importer] WITH SID = 0x{sid.hex()}, TYPE = E"
            )
        cursor.execute(
            "GRANT EXECUTE ON OBJECT::dbo.ImportWorkbook TO [workbook_importer]"
        )


def grant_mail_read(outputs):
    """Assign the Graph Mail.Read application role to the Function identity."""
    graph = az("ad", "sp", "show", "--id", "00000003-0000-0000-c000-000000000000")
    role = next(
        item
        for item in graph["appRoles"]
        if item["value"] == "Mail.Read" and "Application" in item["allowedMemberTypes"]
    )
    principal = outputs["functionPrincipalId"]
    assignments = az(
        "rest",
        "--method",
        "GET",
        "--url",
        f"https://graph.microsoft.com/v1.0/servicePrincipals/{principal}/appRoleAssignments",
    )
    if any(
        item["appRoleId"] == role["id"] and item["resourceId"] == graph["id"]
        for item in assignments["value"]
    ):
        return
    az(
        "rest",
        "--method",
        "POST",
        "--url",
        f"https://graph.microsoft.com/v1.0/servicePrincipals/{principal}/appRoleAssignments",
        "--body",
        json.dumps(
            {
                "principalId": principal,
                "resourceId": graph["id"],
                "appRoleId": role["id"],
            }
        ),
    )


def deploy(args, account):
    if not args.mailbox:
        raise ValueError("deploy requires --mailbox.")
    if not re.fullmatch(r"[a-z][a-z0-9-]{1,18}[a-z0-9]", args.name_prefix):
        raise ValueError(
            "Use a name prefix of 3–20 lowercase letters, digits, or hyphens."
        )
    az("bicep", "build", "--file", str(ROOT / "infra/main.bicep"), "--stdout")
    # The signed-in user or service principal becomes the SQL Entra administrator.
    if account["user"]["type"] == "user":
        operator = az("ad", "signed-in-user", "show")
        admin = ("User", operator["id"], operator["userPrincipalName"])
    else:
        operator = az("ad", "sp", "show", "--id", account["user"]["name"])
        admin = ("Application", operator["id"], operator["displayName"])
    for namespace in (
        "Microsoft.Web",
        "Microsoft.App",
        "Microsoft.Storage",
        "Microsoft.Sql",
        "Microsoft.Logic",
        "Microsoft.ManagedIdentity",
        "Microsoft.Insights",
        "Microsoft.OperationalInsights",
    ):
        provider = az("provider", "show", "--namespace", namespace)
        if provider["registrationState"] != "Registered":
            print(f"Registering {namespace}...", flush=True)
            az("provider", "register", "--namespace", namespace, "--wait")
    az("group", "create", "--name", args.resource_group, "--location", args.location)

    print(f"Deploying into {account['name']} / {args.resource_group}...", flush=True)
    deployment = az(
        "deployment",
        "group",
        "create",
        "--resource-group",
        args.resource_group,
        "--name",
        "showcase",
        "--template-file",
        str(ROOT / "infra/main.bicep"),
        "--parameters",
        f"namePrefix={args.name_prefix}",
        f"location={args.location}",
        f"sqlAdminPrincipalType={admin[0]}",
        f"sqlAdminObjectId={admin[1]}",
        f"sqlAdminLogin={admin[2]}",
        f"mailboxAddress={args.mailbox}",
        f"subjectFilter={args.subject_filter}",
    )
    outputs = {
        key: item["value"] for key, item in deployment["properties"]["outputs"].items()
    }
    grant_mail_read(outputs)
    with sql_access(args.resource_group, outputs):
        bootstrap_sql(outputs)
    print("Publishing the Python Function with a Linux remote build...", flush=True)
    subprocess.run(
        [
            "func",
            "azure",
            "functionapp",
            "publish",
            outputs["functionAppName"],
            "--python",
            "--build",
            "remote",
        ],
        cwd=ROOT,
        check=True,
    )
    print(
        "\nDeployment complete. The workflow is disabled until the mailbox is authorized."
    )
    print(f"Open https://portal.azure.com/#resource{outputs['outlookConnectionId']}")
    print(
        "Select Edit API connection → Authorize → sign in to the demo mailbox → Save."
    )
    print("Then run setup.sh enable with the same subscription and resource group.")


def enable(args, outputs):
    connection = az(
        "resource",
        "show",
        "--ids",
        outputs["outlookConnectionId"],
        "--api-version",
        "2016-06-01",
    )
    if not any(
        item.get("status") == "Connected"
        for item in connection["properties"].get("statuses", [])
    ):
        raise RuntimeError(
            "Authorize and save the Outlook API connection in the Azure portal first."
        )
    az(
        "rest",
        "--method",
        "POST",
        "--url",
        f"https://management.azure.com{outputs['workflowId']}/enable?api-version=2019-05-01",
    )
    print(
        "Workflow enabled. Send a new email with the configured subject and attachment.xlsx."
    )


def verify(args, outputs):
    identity = AzureCliCredential()
    for name in (outputs["importQueueName"], outputs["poisonQueueName"]):
        with QueueClient(outputs["queueEndpoint"], name, credential=identity) as queue:
            count = queue.get_queue_properties().approximate_message_count
            print(f"Queue {name}: approximately {count} messages.")
    with TableClient(
        outputs["tableEndpoint"], outputs["processedTableName"], credential=identity
    ) as table:
        count = sum(
            1
            for _ in table.query_entities(
                "PartitionKey eq 'attachments'", select=["RowKey"]
            )
        )
        print(f"Table Storage contains {count} completed attachment hashes.")
    with (
        sql_access(args.resource_group, outputs),
        connect_sql(local=True) as connection,
    ):
        cursor = connection.cursor()
        cursor.execute("SELECT COUNT(*), COALESCE(SUM([RowCount]), 0) FROM dbo.Imports")
        imports, rows = cursor.fetchone()
        print(f"Database contains {imports} imported attachments / {rows} rows.")
    runs = az(
        "rest",
        "--method",
        "GET",
        "--url",
        f"https://management.azure.com{outputs['workflowId']}/runs?api-version=2019-05-01&$top=5",
    )
    for run in runs.get("value", []):
        print(f"Workflow run {run['name']}: {run['properties']['status']}")
    if not runs.get("value"):
        print(
            "No email runs yet. Send the example workbook to complete the end-to-end check."
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("deploy", "enable", "verify"))
    parser.add_argument("--subscription", required=True)
    parser.add_argument("--resource-group", required=True)
    parser.add_argument("--name-prefix", default="xlsx-demo")
    parser.add_argument("--location", default="westeurope")
    parser.add_argument("--subject-filter", default="Azure Functions showcase")
    parser.add_argument("--mailbox", help="Mailbox address; required for deploy")
    args = parser.parse_args()
    az("account", "set", "--subscription", args.subscription)
    account = az("account", "show")
    if args.command == "deploy":
        deploy(args, account)
    else:
        outputs = deployment_outputs(args.resource_group)
        if args.command == "enable":
            enable(args, outputs)
        else:
            verify(args, outputs)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        print(exc.stderr or str(exc), file=sys.stderr)
        sys.exit(1)
    except (ValueError, RuntimeError, mssql_python.Error) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
