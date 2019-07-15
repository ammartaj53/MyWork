#!/usr/bin/python

import os, boto3
from datetime import date

TODAY = date.today()
BUCKET="espbackup-eu-d8a1d818-87dd-11e7-b78e-9cb6d0d99433"
KEY_FOLDER="ESP_SUPPORT/"

DATE = TODAY.strftime("%Y-%m-%d")
ALL_FILES = os.listdir("/backup/")
FILES_TO_MOVE = [files for files in ALL_FILES if DATE in files]

s3 = boto3.resource('s3')
for FILES in FILES_TO_MOVE:
        s3.meta.client.upload_file('/backup/'+FILES, BUCKET, KEY_FOLDER+FILES)

for FILE_TO_DELETE in ALL_FILES:
        if FILE_TO_DELETE not in FILES_TO_MOVE:
                os.remove('/backup/'+FILE_TO_DELETE)
