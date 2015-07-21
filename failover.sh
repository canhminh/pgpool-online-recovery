#!/bin/bash
failed_node=$1
new_master=$2
trigger_file=$4
old_primary=$3
JAVA_HOME=/usr/java/default
# if standby goes down.
# Send an email with Subject, Body, To 
$JAVA_HOME/bin/java -Dfile.encoding=utf-8 -cp /etc/pgpool/script/*.jar com.newsaigonsoft.sendmail.SendMail "PGPool failover notify" "Node $failed_node is down" username@example.com > /home/postgres/sendmail
if [ $failed_node != $old_primary ]; then
    echo "[INFO] Slave node is down. Failover not triggred !";
    exit 0;
fi
# Create the trigger file if primary node goes down.
echo "[INFO] Master node is down. Performing failover..."
ssh -i /home/postgres/.ssh/id_rsa postgres@$new_master "touch $trigger_file"

exit 0;

