import email
import json
import logging
import os
from email import policy
from email.utils import formataddr, parseaddr

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# SES rejects a resend that keeps these: its own Return-Path/Message-ID, and a DKIM
# signature that no longer matches once From changes.
DROPPED_HEADERS = ("Return-Path", "Sender", "Message-ID", "DKIM-Signature", "Reply-To", "X-Original-From")


def object_key(recipient, message_id):
    local, _, domain = recipient.lower().partition("@")
    return f"{domain}/{local}/{message_id}"


def single_line(value):
    return " ".join(str(value or "").split())


def build_forward(raw, recipient):
    message = email.message_from_bytes(raw, policy=policy.compat32)
    original_from = single_line(message.get("From"))
    name, address = parseaddr(original_from)
    for header in DROPPED_HEADERS:
        del message[header]
    del message["From"]
    message["From"] = formataddr((f"{name or address} via {recipient}", recipient))
    if address:
        message["Reply-To"] = original_from
    message["X-Original-From"] = original_from
    return message.as_bytes(policy=policy.compat32.clone(linesep="\r\n"))


def handle(event, s3, ses, bucket, rules):
    sent = []
    for record in event.get("Records", []):
        payload = record["ses"]
        message_id = payload["mail"]["messageId"]
        recipients = [r.lower() for r in payload["receipt"]["recipients"]]
        for recipient in recipients:
            target = rules.get(recipient)
            if not target:
                logger.info("No forward rule for %s", recipient)
                continue
            key = object_key(recipient, message_id)
            raw = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
            data = build_forward(raw, recipient)
            ses.send_raw_email(Source=recipient, Destinations=[target], RawMessage={"Data": data})
            logger.info("Forwarded %s for %s", key, recipient)
            sent.append(key)
    return {"forwarded": sent}


def load_rules(text):
    rules = json.loads(text or "{}")
    if not isinstance(rules, dict):
        raise ValueError("FORWARD_RULES must be a JSON object of recipient to target address.")
    return {str(k).lower(): str(v) for k, v in rules.items()}


def handler(event, context):
    import boto3

    region = os.environ.get("AWS_REGION", "us-east-1")
    return handle(
        event,
        boto3.client("s3", region_name=region),
        boto3.client("ses", region_name=region),
        os.environ["MAIL_BUCKET"],
        load_rules(os.environ.get("FORWARD_RULES")),
    )
