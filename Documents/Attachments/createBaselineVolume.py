# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import boto3
import botocore
import math
from botocore.exceptions import ClientError
import sys
    

def runinstance(image_id, instance_type,
            subnet_id,
            security_group_id, device_name,
            automation_id, userdata):

    response_instance=ec2_client.run_instances(
        ImageId = image_id,
        InstanceType = instance_type,
        SubnetId = subnet_id,
        SecurityGroupIds = [
          security_group_id,
          ],
        MaxCount=1,
        MinCount=1,
        UserData=userdata,
        BlockDeviceMappings=[
          {
            'DeviceName': device_name,
            'Ebs': {
              'DeleteOnTermination': False
            },
          },
        ],
        TagSpecifications= [
            {
                'ResourceType': 'instance' ,
                'Tags': [
                    {
                        'Key':'Name',
                        'Value': 'BaselineInstance_BackupOutpostsServerInstance'
                    },
                    {
                        'Key':'SSMautomation_id',
                        'Value': automation_id
                    },    
                ]
            }
        ]
        )
        
    print('[INFO] Launched EC2 instance', response_instance['Instances'][0]['InstanceId'])
    
    return response_instance
    
def WaitForInstanceToBeRunning(InstanceId):
    try:
        print('[INFO] Waiting for new instance to reach running state: ', InstanceId)
        waiter = ec2_client.get_waiter('instance_running')
        waiter.wait (
            InstanceIds=[
                InstanceId
            ],
        )
        print('[INFO] Launched instance is now in Running state: ', InstanceId)

    except ClientError as error:
        print('[ERROR] Launched instance is not Running: ', InstanceId)
        raise error
        
def WaitForInstanceToBeTerminated(InstanceId):
    try:
        print('[INFO] Waiting for new instance to reach Terminated state: ', InstanceId)
        waiter = ec2_client.get_waiter('instance_terminated')
        waiter.wait (
            InstanceIds=[
                InstanceId
            ],
        )
        print('[INFO] Launched instance is now in Terminated state: ', InstanceId)

    except ClientError as error:
        print('[ERROR] Launched instance is not Terminated: ', InstanceId)
        raise error
        
def getImageByStartTime(InstanceId):
  ec2 = boto3.client('ec2')
  instance_id = InstanceId

  response = ec2.describe_images(
    Filters=[
            {
              "Name": "name",
              "Values": ["BackupOutpostsServerInstance-"+instance_id+"*"]
            }
          ]
    ) 
  ami_list = response

  while "NextToken" in response:
    response = ec2.describe_images(
    Filters=[
            {
              "Name": "name",
              "Values": ["BackupOutpostsServerInstance-"+instance_id+"*"]
            }
          ],
    NextToken=response["NextToken"]
    )
    ami_list.extend(response)

  source_ami_id = ec2.describe_instances(
    InstanceIds=[
            instance_id,
        ],
  )['Reservations'][0]['Instances'][0]['ImageId']

  if not ami_list['Images']:
    baseline_ami_id = source_ami_id
  else:
    json_ami = ami_list['Images']
    sorted_amis = sorted(json_ami, key=lambda k: k['CreationDate'], reverse=True)
    latest_sorted_ami_id = sorted_amis[0]['ImageId']
    baseline_ami_id = latest_sorted_ami_id

  return baseline_ami_id

def create_baseline_volume_handler(events,context):
    try:
        global ec2_client
        ec2_client = boto3.client('ec2')
        
        instance_id = events['InstanceId']
        image_id = events['AmiId']
        
        if(image_id == 'SelectAutomatically'):
          image_id=getImageByStartTime(instance_id)
        
        instance_type = events['InstanceType']
        subnet_id = events['SubnetId']
        volume_az = events['VolumeAZ']
        security_group_id = events['SecurityGroupId']
        volume_sizeGB = events['VolumeSize']
        device_name = events['DeviceMapping']
        userdata=f"""#cloud-config
        resize_rootfs: false
        growpart: false
        resizefs: false
        """
        
        volume_sizeGiB = math.ceil(volume_sizeGB*0.93132)
        
        response = ec2_client.describe_images(
          ImageIds=[
            image_id,
          ],
        )
        
        block_device_mapping = response['Images'][0]['BlockDeviceMappings']
        
        root_device_name = response['Images'][0]['RootDeviceName']
        
        snapshot_id = None
        
        for device in block_device_mapping:
          if device['DeviceName'] == root_device_name:
            snapshot_id = device['Ebs']['SnapshotId']
            break
            
        if snapshot_id is None:
          raise ValueError("Root volume snapshot not found in the block device mapping.")
          
        # Check if the snapshot is visible in the account
        snapshot_response = ec2_client.describe_snapshots(
          Filters=[
            {
              'Name': 'snapshot-id',
              'Values': [
                snapshot_id,
              ]
            }
          ],
        )
        
        volume_id = None
        
        if not snapshot_response['Snapshots']:
          launched_instance=runinstance(
            image_id, instance_type,
            subnet_id, security_group_id, device_name,
            context['automation:EXECUTION_ID'],
            userdata
            )
          launched_instance_id=launched_instance['Instances'][0]['InstanceId']
          WaitForInstanceToBeRunning(launched_instance_id)
          root_device_name=launched_instance['Instances'][0]['RootDeviceName']
          root_volume = ec2_client.describe_volumes(
            Filters=[
              {
                'Name':'attachment.instance-id',
                'Values': [
                        launched_instance_id,
                ],
              },
              {
                'Name':'attachment.device',
                'Values': [
                        launched_instance['Instances'][0]['RootDeviceName'],
                ],
              },
            ],
          )

          volume_id=root_volume['Volumes'][0]['Attachments'][0]['VolumeId']
          
          ec2_client.terminate_instances(
            InstanceIds=[
              launched_instance_id,
            ],
          )
          WaitForInstanceToBeTerminated(launched_instance_id)
        else:
          response = ec2_client.create_volume(
            SnapshotId=snapshot_id,
            AvailabilityZone=volume_az,
            Size=volume_sizeGiB
          )
          volume_id = response['VolumeId']
        
        response = ec2_client.describe_volumes(
          VolumeIds=[
            volume_id,
          ],
        )
        
        response_volume = response['Volumes'][0]
        volume_size = response_volume['Size']
        
        if volume_size != volume_sizeGiB:
          response = ec2_client.modify_volume(
            VolumeId=volume_id,
            Size=volume_sizeGiB
          )
        
        return{
            "baselineVolumeId": volume_id,
            "baselineAmiId": image_id,
            "volumeSizeGiB": volume_sizeGiB
        }

    except botocore.exceptions.WaiterError as e:
        c = e.last_response['Error']['Code']
        m = e.last_response['Error']['Message']
        sys.exit (("[ERROR] An error occurred while waiting for the instance status to stabiize (Running or Terminate) - {}:{} ").format(c,m))
    except botocore.exceptions.ParamValidationError as e:
        sys.exit('[ERROR] The parameters provided are incorrect: {}'.format(e.args[0]))
    except ClientError as e:
        c = e.response['Error']['Code']
        m = e.response['Error']['Message']
        sys.exit((("[ERROR] An error occurred when calling the EC2 APIs - {}:{} ").format(c,m)))
    except Exception as ex:
        raise Exception (f'[ERROR] Unexpected exception occurred while executing the code - {ex}')