# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import sys
import boto3
from datetime import datetime, timezone
from botocore.exceptions import ClientError
from botocore.config import Config

config = Config(
   retries = {
      'max_attempts': 10,
      'mode': 'standard'
   }
)

sys.tracebacklimit = 0
ssm = boto3.client('ssm', config=config)


def check_concurrency_handler(events, context):

    try:
        current_execution = ssm.describe_automation_executions(
            Filters=[{'Key': 'ExecutionId',
                      'Values': [context['automation:EXECUTION_ID']]}])['AutomationExecutionMetadataList'][0]

        current_execution_id = current_execution['AutomationExecutionId']

        if current_execution.get('Target'):
            instance_id = current_execution['Target']
        else:
            instance_id = next(iter(ssm.get_automation_execution(AutomationExecutionId=current_execution_id)[
                               'AutomationExecution'].get('Parameters', []).get('InstanceId', [])), '')

        if not instance_id:
            return

        current_execution_start_time = datetime.fromtimestamp(
            current_execution['ExecutionStartTime'].timestamp(), timezone.utc)
        document_executions = ssm.describe_automation_executions(
            Filters=[{'Key': 'DocumentNamePrefix', 'Values': [current_execution['DocumentName']]},
                     {'Key': 'ExecutionStatus', 'Values': ['InProgress']},
                     {'Key': 'StartTimeBefore', 'Values': [
                         current_execution_start_time.strftime('%Y-%m-%dT%H:%M:%SZ')]}
                     ])['AutomationExecutionMetadataList']

        for execution in document_executions:
            execution_id = execution['AutomationExecutionId']
            if execution_id != current_execution_id:
                if execution.get('Target', '') == instance_id:
                    raise Exception('There is another execution of this document already in progress for {} with id {}'.format(
                        instance_id, execution['AutomationExecutionId']))

                execution_details = ssm.get_automation_execution(AutomationExecutionId=execution_id)[
                    'AutomationExecution'].get('Parameters', []).get('InstanceId', [])
                execution_instance_id = next(iter(execution_details), '')
                if execution_instance_id == instance_id:
                    raise Exception('There is another execution of this document already in progress for {} with id {}'.format(
                        instance_id, execution['AutomationExecutionId']))

    except ClientError as e:
        c = e.response['Error']['Code']
        m = e.response['Error']['Message']
        raise Exception(
            f'An error occurred when checking concurrent executions: {c}:{m}')

    return