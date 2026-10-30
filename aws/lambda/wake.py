"""POST /wake (through CloudFront): starts the ERAS server when it sleeps and says in what state it is."""
import hmac
import json
import os

import boto3

ec2 = boto3.client("ec2")


def respond(status, body):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json", "cache-control": "no-store"},
        "body": json.dumps(body),
    }


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if not hmac.compare_digest(headers.get("x-eras-origin", ""), os.environ["ORIGIN_SECRET"]):
        return respond(403, {"error": "forbidden"})

    instance_id = os.environ["INSTANCE_ID"]
    reservation = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"][0]
    state = reservation["Instances"][0]["State"]["Name"]
    if state == "stopped":
        ec2.start_instances(InstanceIds=[instance_id])
        state = "pending"
    # running: the services may still be starting; stopping: the front asks again when its next request fails.
    return respond(200 if state == "running" else 202, {"state": state})
