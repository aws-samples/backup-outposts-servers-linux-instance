# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import base64
import os
import json
import argparse
from collections import OrderedDict
import hashlib
from zipfile import ZipFile

DOCUMENT_DIR = os.path.abspath(os.path.join(
    os.path.dirname(os.path.realpath(__file__)),
    "../Documents"
))
SCRIPT_DIR = os.path.abspath(os.path.join(
    os.path.dirname(os.path.realpath(__file__)),
    "../Documents/Scripts"
))

ATTACHMENTS_DIR = os.path.abspath(os.path.join(
    os.path.dirname(os.path.realpath(__file__)),
    "../Documents/Attachments"
))

OUTPUT_ATTACHMENTS_DIR = os.path.abspath(os.path.join(
    os.path.dirname(os.path.realpath(__file__)),
    "../Output/Attachments"
))

CFN_DIR = os.path.abspath(os.path.join(
    os.path.dirname(os.path.realpath(__file__)),
    "../Documents/CloudFormationTemplates"
))

def zip_attachments_folder(template, file_name):
    if os.path.exists(ATTACHMENTS_DIR):
        if os.listdir(ATTACHMENTS_DIR):
            if not os.path.exists(OUTPUT_ATTACHMENTS_DIR):
                os.makedirs(OUTPUT_ATTACHMENTS_DIR)
            
            with ZipFile(os.path.join(OUTPUT_ATTACHMENTS_DIR, file_name), 'w') as zipObj:
                for root, _, files in os.walk(ATTACHMENTS_DIR):
                    for f in files:
                        zipObj.write(os.path.join(root, f), arcname=os.path.join(root.replace(ATTACHMENTS_DIR, ""), f))

            with open(os.path.join(OUTPUT_ATTACHMENTS_DIR,file_name),"rb") as f:
                bytes = f.read()
                readable_hash = hashlib.sha256(bytes).hexdigest()

                if template.get("files"):
                    template["files"].update({ file_name: {"checksums": {"sha256": readable_hash }}})
                else:
                    template["files"] = { file_name: {"checksums": {"sha256": readable_hash }}}

def insert_runcommand_in_document(template, step_name, file_name):
    newline = ""
    for step in template["mainSteps"]:
        if step["name"] == step_name:
            step["inputs"]["Parameters"]["commands"] = ""
            with open(os.path.join(SCRIPT_DIR, file_name), 'r') as f:
                for line in f:
                    #step["inputs"]["Script"] += \
                    [line.replace('\n', '').replace('\r', '').replace('\t', '    ')]
                    line = line.rstrip('\n')
                    newline = newline + line + '\n'
            step["inputs"]["Parameters"]["commands"] += newline
            break

def insert_cloudformation_in_document(template, step_name, file_name):
    newline = ""
    for step in template["mainSteps"]:
        if step["name"] == step_name:
            step["inputs"]["TemplateBody"] = ""
            with open(os.path.join(CFN_DIR, file_name), 'r') as f:
                for line in f:
                    [line.replace('\n', '').replace('\r', '').replace('\t', '    ')]
                    line = line.rstrip('\n')
                    newline = newline + line + '\n'
            step["inputs"]["TemplateBody"] += newline
            break

def insert_script_in_document(template, step_name, file_name):
    for step in template["mainSteps"]:
        if step["name"] == step_name:
            step["inputs"]["Parameters"]["commands"] = []
            with open(os.path.join(SCRIPT_DIR, file_name), 'r') as f:
                for line in f:
                    step["inputs"]["Parameters"]["commands"] += [line.replace('\n', '').replace('\r', '').replace('\t', '    ')]
            break

def insert_executescript_in_document(template, step_name, file_name):
    newline = ""
    for step in template["mainSteps"]:
        if step["name"] == step_name:
            step["inputs"]["Script"] = ""
            with open(os.path.join(SCRIPT_DIR, file_name), 'r') as f:
                for line in f:
                    [line.replace('\n', '').replace('\r', '').replace('\t', '    ')]
                    line = line.rstrip('\n')
                    newline = newline + line + '\n'
            step["inputs"]["Script"] += newline
            break

def insert_zip_file_in_execute_script_step(template, step_name, file_name):
    for step in template["mainSteps"]:
        if step["name"] == step_name:
            if step["inputs"].get("Attachment"):
                step["inputs"]["Attachment"] = file_name
            break

def insert_template_url_in_document(template, step_name, test_url):
    for step in template["mainSteps"]:
        if step["name"] == step_name:
            step["inputs"]["TemplateURL"] = test_url

def open_document(file_name):
    document = os.path.normpath(os.path.join(DOCUMENT_DIR, file_name))
    with open(document) as fp:
        return json.load(fp, object_pairs_hook=OrderedDict)

def process(document_name):
    document = open_document(document_name)
    insert_cloudformation_in_document(document, "stageCreateHelperInstanceAutomation", "stageCreateHelperInstanceAutomation.yaml")
    insert_script_in_document(document, 'checkOSRequirements', 'checkOSRequirements.sh')
    insert_script_in_document(document, 'replicatePartitionAndRsync', 'replicatePartitionAndRsync.sh')
    ZIP_FILE_NAME = 'attachment.zip'
    zip_attachments_folder(document, ZIP_FILE_NAME)
    print(json.dumps(document, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("--document_name", help = "Automation Document Name", nargs="*",
                        default = None)
    args = parser.parse_args()
    process(args.document_name[0])

