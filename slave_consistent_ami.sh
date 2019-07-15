#!/bin/sh
#
# By Ammar Taj 03/05/2019
# This script will stop the slave and create the consistent AMI from slave server.
# At the end, it will deregister the 5days older AMI and delete the associated snapshots.


LAST_IO_ERROR=$(/usr/bin/mysql -e "SHOW SLAVE STATUS\G"| grep -w "Last_IO_Errno" | awk '{ print $2 }')
LAST_SQL_ERROR=$(/usr/bin/mysql -e "SHOW SLAVE STATUS\G"| grep -w "Last_SQL_Errno" | awk '{ print $2 }')

if [ $LAST_IO_ERROR -eq 0 -a $LAST_SQL_ERROR -eq 0 ]; then


	/usr/bin/mysql -e "STOP SLAVE;"

	MASTER_LOG_FILE=$(/usr/bin/mysql -e "SHOW SLAVE STATUS\G"| grep -w "Master_Log_File" | awk '{ print $2 }')
	READ_MASTER_LOG_POS=$(/usr/bin/mysql -e "SHOW SLAVE STATUS\G"| grep -w "Read_Master_Log_Pos" | awk '{ print $2 }')
	REGION=$(curl -s "http://169.254.169.254/latest/meta-data/placement/availability-zone" | sed 's/.$//')


	INSTANCE_ID=$(curl -s "http://169.254.169.254/latest/meta-data/instance-id")

	AMI_ID=$(/home/backup/bin/aws ec2 create-image --region ${REGION}  --instance-id ${INSTANCE_ID} --name $HOSTNAME-$(date --iso)-${MASTER_LOG_FILE}-${READ_MASTER_LOG_POS} --no-reboot | grep "ImageId" | awk '{gsub(/[" ,]/, "", $2); print $2}')

# Condition to check if ami creation is triggered or not

	if [ -z $AMI_ID ]; then

		/usr/bin/mysql -e "START SLAVE;"

		SLACK_MESSAGE="$HOSTNAME :- No ami created"
		SLACK_URL=https://hooks.slack.com/services/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
		SLACK_ICON=':red_circle:'

		curl -s -X POST --data "payload={\"text\": \"${SLACK_ICON} ${SLACK_MESSAGE}\"}" ${SLACK_URL}

		exit;

	fi


# Check until ami is available.

	CURR_STATE="pending"

	until [ ! ${CURR_STATE} == "pending" ]

	do
		sleep 20;
		CURR_STATE=$(/home/backup/bin/aws ec2 describe-images --region ${REGION} --image-id ${AMI_ID} | grep "State" | awk '{gsub(/[" ,]/, "", $2); print $2}')
	done

# Post ami-id to slack channel.

	SLACK_MESSAGE="$HOSTNAME :- ${AMI_ID} is now ${CURR_STATE}"
	SLACK_URL=https://hooks.slack.com/services/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
	SLACK_ICON=':heavy_check_mark:'

	curl -s -X POST --data "payload={\"text\": \"${SLACK_ICON} ${SLACK_MESSAGE}\"}" ${SLACK_URL}

	/usr/bin/mysql -e "START SLAVE;"

# Deregistering AMI older than 5days and deleting associsted snapshots

	image_to_deregister=$(/home/backup/bin/aws ec2 describe-images --region ${REGION} --filters "Name=creation-date,Values=$(date +%Y-%m-%d --date "5 days ago")*"  "Name=name,Values=ukrptdbaws-slave.espreporting.com*" | grep ImageId | awk '{gsub (/[" ,]/, "", $2); print $2}')

	if [ ! -z $image_to_deregister ]; then

		snap_to_delete=$(/home/backup/bin/aws ec2 describe-images --region ${REGION} --filters "Name=creation-date,Values=$(date +%Y-%m-%d --date "5 days ago")*"  "Name=name,Values=ukrptdbaws-slave.espreporting.com*" | grep SnapshotId | awk '{gsub (/[" ,]/, "", $2); print $2}')


		/home/backup/bin/aws ec2 deregister-image --region ${REGION} --image-id $image_to_deregister

		if [  $? -eq 0 ]; then

			echo "$image_to_deregister is deregistered."

		fi

		for snapID in ${snap_to_delete[@]}
		do
			/home/backup/bin/aws ec2 delete-snapshot --region ${REGION} --snapshot-id $snapID
			if [  $? -eq 0 ]; then
				echo "$snapID is deleted"
			fi
			sleep 3
		done

	else

		echo "No AMI to deregister."

	fi

else

echo "Error in Slave. Please check. Cannot proceed with consistent AMI creation."

fi
