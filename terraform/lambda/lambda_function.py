import json
import os
import boto3
from datetime import datetime, timezone

s3 = boto3.client("s3")
BUCKET_NAME = os.environ["BUCKET_NAME"]


def handler(event, context):
    for record in event["Records"]:
        sns_message = record["Sns"]["Message"]
        message_id = record["Sns"]["MessageId"]

        timestamp = datetime.now(timezone.utc).strftime("%Y/%m/%d/%H%M%S")
        key = f"zabbix-alerts/{timestamp}-{message_id}.json"

        s3.put_object(
            Bucket=BUCKET_NAME,
            Key=key,
            Body=sns_message.encode("utf-8"),
            ContentType="application/json",
        )

        print(f"Archived alert to s3://{BUCKET_NAME}/{key}")

    return {"statusCode": 200, "body": json.dumps({"archived": len(event["Records"])})}
