# BackupOutpostsServerLinuxInstanceToEBS

## Description

This automation runbook creates an EBS-backed AMI in region storing the data of the instance store root volume of the Linux instance running on Outposts Server. The automation uses a helper instance in Region to replicate the partitioning and the data of the mounted File System (FS) from the instance store root volume to an EBS volume. By default this EBS volume is restored from the most recent Backup and users can specify the desired backup in the input parameters. If no backup is found with the default option (e.g. when doing the first backup), the EBS volume is created from the AMI from which the outpost server instance was launched.

## Prerequisites

- The EC2 instance to backup must be managed by AWS System Manager (SSM) and running on Outpost Server. The role attached to the instance must also provide the permissions to execute "ssm:GetParameter". You can use a role with the policy "AmazonSSMManagedInstanceCore" attached to provide all the necessary permissions to the EC2 instance running on Outposts Server
- There must be a Subnet in Region in the same VPC of the Outposts Server Subnet to launch the Helper instance.
- The outbound rules (SG/nACL/OS Firewall) applied to the instance running on Outposts Server must allow the SSH connectivity towards the private CIDR of the Subnet in Region outlined in the previous point.
- aws cli, rsync (version >= 3.1.2) and sfdisk (version >= 2.26) installed on the instance running on Outposts Server

## Limitations

The current version supports only the backup of ext4, xfs and vfat filesystems built on top of "raw" disk partitions.

## Important:

Executing this runbook, may incur extra charges to your account for the EC2 instance, EBS Volumes, and Amazon Machine Images (AMIs). Please refer to the [Amazon EC2 Pricing](https://aws.amazon.com/ec2/pricing/) and [Amazon EBS pricing](https://aws.amazon.com/ebs/pricing/) for more details.

## Installation Instructions

1. Open the Cloudshell or a client with the AWS CLI and python3 installed that can access the Account of the Outposts Server instance where you want to run the Automation
2. Clone the source code hosted on GitHub and cd into it with the command:
```
git clone https://github.com/aws-samples/backup-outposts-servers-linux-instance.git
cd backup-outposts-servers-linux-instance
```
3. Build the SSM Automation document with its Attachments with the command:
```
make documents
```
4. Upload the Output/Attachments/attachment.zip file to an S3 Bucket of your choice and create the SSM Automation Document. **BUCKET_NAME** is the name of the S3 Bucket where you want to upload the attachments, **DOC_NAME** is the name you want to give to this Automation and **OUTPOST_REGION** is the AWS Region where your Outpost Server resides:
```
BUCKET_NAME="bucket-for-attachments"
DOC_NAME="BackupOutpostsServerLinuxInstanceToEBS"
OUTPOST_REGION="region-of-outpost"
aws s3 cp Output/Attachments/attachment.zip s3://${BUCKET_NAME}
aws ssm create-document --content file://Output/BackupOutpostsServerLinuxInstanceToEBS.json --name ${DOC_NAME} --document-type "Automation" --document-format JSON --attachments Key=S3FileUrl,Values=s3://${BUCKET_NAME}/attachment.zip,Name=attachment.zip --region ${OUTPOST_REGION}
```
## Usage Instructions

1. Open the AWS Console and go to Systems Manager > Documents > “Owned by me” in the region where you deployed the SSM Automation
1. Select the document name you specified when following the "Installation Instructions" and click on “Execute automation”
1. Fill-in the input parameters and click on "Execute". Familiarize yourself with the document by reading through the parameters and steps description.

## Parameters

### InstanceId

- **Type**: AWS::EC2::Instance::Id
- **Description**: (Required) ID of the EC2 instance running on Outposts Server that you want to backup.

### AmiId

- **Type**: String
- **Description**: (Required) ID of the AMI from a previous backup to use as a baseline for the incremental backup. If you leave the default SelectAutomatically option, the Document will search for any previous backup and it will take the most recent one created with this Automation. If this is the first backup or no previous backup is found (e.g. because the previous backups were deleted), the Document will use the base AMI from which the instance was launched
- **Allowed Pattern**: ^SelectAutomatically$|^ami-[a-f0-9]{17}$
- **Default**: SelectAutomatically

### SubnetId

- **Type**: String
- **Description**: (Required) The subnet ID in Region to create the helper instance. IMPORTANT: The Outposts Server instance will need to communicate with the helper instance using its private IP and the SSH port, so you must specify a subnet whose private CIDR is reachable from the Outposts Server instance (e.g. a Subnet in region in the same VPC of the Outposts Server).
- **Allowed Pattern**: ^subnet-[a-f0-9]{17}\$|^subnet-[a-f0-9]{8}$

### TemporaryInstancesType

- **Type**: String
- **Description**: (Required) The EC2 instance type of the helper and baseline instances. The CPU arch of the selected instance type must be the same of the instance to backup (e.g. specify Graviton instance type if your Outposts Server instance is running on 1U server). Xen instance types are not Supported.
- **Allowed Pattern**: ^((c5|c5a|c5ad|c5d|c5n|c6a|c6g|c6gd|c6gn|c6i|c6id|c7g|c7gn|g4ad|g4dn|g5|g5g|i3en|i4i|im4gn|inf1|is4gen|m5|m5a|m5ad|m5d|m5dn|m5n|m5zn|m6a|m6g|m6gd|m6i|m6id|m7g|p3dn|p4d|r5|r5a|r5ad|r5b|r5d|r5dn|r5n|r6a|r6g|r6gd|r6i|r6id|r7g|t3|t3a|t4g|trn1|u-12tb1|u-3tb1|u-6tb1|u-9tb1|vt1|x2gd|x2idn|x2iedn|x2iezn|z1d)\.(10xlarge|112xlarge|12xlarge|16xlarge|18xlarge|24xlarge|2xlarge|32xlarge|3xlarge|48xlarge|4xlarge|56xlarge|6xlarge|8xlarge|9xlarge|large|medium|metal|micro|nano|small|xlarge))$
- **Default**: c5.large

### MaxThroughput

- **Type**: String
- **Description**: (Optional) the maximum throughput in MiB/s allowed for the data sync.  Leave 0 (default option) if you do not want to set a limitation
- **Allowed Pattern**: ^[0-9]{1,10}$
- **Default**: 0

### Exclusions

- **Type**: String
- **Description**: (Optional) the list of space-separated file and/or directory names, paths or patterns matching the files/directories/paths that you want to exclude from the backup. e.g. /data/ephemeral *.swp /data/temporarycache dummyfile. Leave empty if you do not want to exclude anything from the backup.
- **Allowed Pattern**: ^.{0,1024}$

### UniqueId

- **Type**: String
- **Description**: (Required) A unique identifier for the workflow.
- **Allowed Pattern**: \{\{ automation:EXECUTION_ID \}\}|^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$
- **Default**: {{ automation:EXECUTION_ID }}

### AssumeRole

- **Type**: AWS::IAM::Role::Arn
- **Description**: (Optional) The Amazon Resource Name (ARN) of the AWS Identity and Access Management (IAM) role that allows Systems Manager Automation to perform the actions on your behalf. If no role is specified, Systems Manager Automation uses the permissions of the user that starts this runbook. For more information, visit - https://docs.aws.amazon.com/systems-manager/latest/userguide/automation-setup.html

## Required IAM Permissions to run this runbook

The AutomationAssumeRole or IAM user, requires the following permissions to successfully run this automation. For more information on how to create a role for your automation and assign the necessary permissions to it, please visit - https://docs.aws.amazon.com/systems-manager/latest/userguide/automation-setup-iam.html

- **ec2:DescribeImages**
- **ec2:DescribeSnapshots**
- **ec2:DescribeVolumes**
- **ec2:DescribeSubnets**
- **ec2:DescribeLaunchTemplates**
- **ec2:DescribeInstances**
- **ec2:DescribeInstanceStatus**
- **ec2:DescribeInstanceTypes**
- **ec2:DescribeSecurityGroupRules**
- **ec2:DescribeSecurityGroups**
- **ec2:DescribeKeyPairs**
- **ssm:DescribeInstanceInformation**
- **ssm:DescribeAutomationExecutions**
- **ssm:GetAutomationExecution**
- **ssm:ListCommandInvocations**
- **ssm:ListCommands**
- **ssm:GetParameters**
- **cloudformation:DescribeStacks**
- **cloudformation:DescribeStackResource**
- **cloudformation:DescribeStackEvents**
- **ec2:CreateSecurityGroup**
- **ec2:RevokeSecurityGroupEgress**
- **ec2:AuthorizeSecurityGroupIngress**
- **ec2:AuthorizeSecurityGroupEgress**
- **ec2:RunInstances**
- **ec2:TerminateInstances**
- **ec2:CreateVolume**
- **ec2:DeleteVolume**
- **ec2:ModifyVolume**
- **ec2:CreateKeyPair**
- **ec2:DeleteKeyPair**
- **ec2:CreateLaunchTemplate**
- **ec2:CreateTags**
- **ec2:AttachVolume**
- **ec2:StartInstances**
- **ec2:StopInstances**
- **ec2:CreateSnapshot**
- **ec2:RegisterImage**
- **ec2:DeleteSecurityGroup**
- **ec2:DeleteLaunchTemplate**
- **ssm:SendCommand**
- **ssm:PutParameter**
- **ssm:DeleteParameter**
- **cloudformation:CreateStack**
- **cloudformation:DeleteStack**

## How to create your own version

To create your own version of this Automation, leveraging the existing SSM Document, Scripts and Framework, you can perform the following steps:
1. Apply your Customizations inside the "Documents" folder, e.g. modifying the SSM Document, modifying the existing python and bash scripts or adding new scripts
1. Repeat the "Installation Instructions" using your local repository where you applied the Customizations in the "Documents" folder instead of cloning the repository from github

## Document Type

Automation

## Document Version

1

## Document Steps

1. **ensureNoConcurrentExecutionsForTargetInstance - aws:executeScript**: Ensures there is only one execution of this runbook targeting the provided EC2 instance. 
1. **assertInstanceStatus - aws:assertAwsResourceProperty**: Make sure the Outposts Server instance is in 'running' state.
1. **assertEC2OutpostsServerInstanceConnectedwithSSM - aws:assertAwsResourceProperty**: Make sure the Outposts Server instance is a SSM managed instance.
1. **assertInstancePlatformIsLinux - aws:assertAwsResourceProperty**: Checks the provided Instance's platform is Linux.
1. **describeInstance - aws:executeAwsApi**: Describes the provided instance.
1. **assertInstanceRootVolumeIsInstanceStore - aws:assertAwsResourceProperty**: Checks the root volume device type is instance-store.
1. **checkOSRequirements - aws:runCommand**: Checks the OS software requirements before starting
1. **getAZfromSubnetParameter - aws:executeAwsApi**: Retrieves the AZ from the Subnet provided in the input parameters
1. **getDefaultRootVolumeSizeForInstanceType - aws:executeAwsApi**: Retrieves the size of the Instance store root volume from the Instance type
1. **getOutpostsServerSubnetCIDR - aws:executeAwsApi**: get the CIDR of the Outposts Subnet. This will be used to allow the traffic from this CIDR in the SG of the Helper instance
1. **stageCreateHelperInstanceAutomation - aws:createStack**: Deploys the EC2 Helper Instance CloudFormation stack.
1. **waitForEC2HelperInstanceCreation - aws:waitForAwsResourceProperty**: Waits for the EC2 Helper CloudFormation stack update to complete.
1. **describeStackOutput - aws:executeAwsApi**: Describes the EC2Helper CloudFormation stack Output to obtain the id of the helper instance, its private IP, its SSH key ID and the security group id to isolate the Baseline instance.
1. **createBaselineVolume - aws:executeScript**: Creates the Baseline Volume used to sync the data of the Outpost Server instance. If an AMI-ID is provided in the input parameter, this volume is created from the snapshot of the root device of that AMI. If the default automatic selection is used, this step will create a volume from the most recent backup performed. If this is the first backup this step will use the source AMI of the Outpost Server instance. If the snapshots of the Baseline AMI are not directly accessible, this step will create a Baseline instance from the AMI first and then terminate it immediately, preserving the volume that will be used as the Baseline volume.
1. **describeImage - aws:executeAwsApi**: Describes the ImageId of the BaselineInstance and check if it has markeplace product code associated to it.
1. **branchOnMarketplaceProductCodeType - aws:branch**: Checks if the Baseline AMI has a Marketplace product code associated. If so, the helper instance needs to be stopped before attaching the volume to it.
1. **stopHelperInstance - aws:changeInstanceState**: Stop the Helper instance before attaching the volume if it has Markeplace product code associated.
1. **forceStopInstance - aws:changeInstanceState**: Forces stop the Helper instance.
1. **attachInstanceRootVolumeToLinuxEC2HelperInstance - aws:executeAwsApi**: Attaches the EBS baseline root volume back to Linux EC2 Helper instance as /dev/sdf.
1. **waitForInstanceRootVolumeToBeAttachedToLinuxEC2HelperInstance - aws:waitForAwsResourceProperty**: Waits for the EBS root volume status is in-use.
1. **startLinuxHelperInstance - aws:changeInstanceState**: Start or make sure the Helper instance is running after attaching the volume.
1. **waitForLinuxHelperInstanceStatusChecks - aws:waitForAwsResourceProperty**: Make sure the Linux Helper EC2 instance is passing the Instance Reachability check
1. **replicatePartitionAndRsync - aws:runCommand**: Execute the script to replicate the partitioning, the FS layout and sync the content of the FS
1. **createSnapshotAfterSynch - aws:executeAwsApi**: Create a snapshot of the EBS volume attached to the target instance where the data was synched
1. **stopHelperInstanceAfterSnapshot - aws:changeInstanceState**: Stop the Helper instance after starting the snapshot creation and while waiting for its completion.
1. **forceStopInstanceAfterSnapshot - aws:changeInstanceState**: Forces stop the Helper instance.
1. **waitForSnapshotCompletion - aws:waitForAwsResourceProperty**: Wait for the completion of the EBS snapshot before creating an AMI from it.
1. **createAMIFromSnapshot - aws:executeAwsApi**: Create an AMI from the EBS snapshot created previously
1. **describeCloudFormationErrorFromStackEvents - aws:executeAwsApi**: Describes errors from the EC2 Helper Instance CloudFormation stack.
1. **waitForCloudFormationStack - aws:waitForAwsResourceProperty**: Waits until the AWS CloudFormation stack is in a terminal status before deleting it.
1. **unstageCreateHelperInstanceAutomation - aws:deleteStack**: Deletes the CreateHelperInstanceAutomation CloudFormation stack.
1. **cleanupBaselineInstanceRootVolume - aws:executeAwsApi**: Delete the Baseline instance's EBS root volume.

