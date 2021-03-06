#!/bin/bash

##This is meanst to be run on the slave, with the masters ip as the passed variable. ($1)
sourcehost="$1"
datadir=/home/postgres/data
archivedir=/home/postgres/archive
archivedirdest=/home/postgres/archive

#Usage
if [ "$1" = "" ] || [ "$1" = "-h" ] || [ "$1" = "-help" ] || [ "$1" = "--help" ];
then
	echo "Usage: $0 masters ip address"
exit 0
fi
#This script must be run as postgres user
Whoami () {
    if [[ $(whoami) != "root" ]]
    then
        echo "[INFO] This script must be run as root user !"
	exit 1
    fi
}

#Check if postgres server is running on remote host
CheckIfPostgresIsRunningOnRemoteHost () {
	isrunning="$(ssh postgres@"$1" 'if killall -0 postmaster; then echo "postgres_running"; else echo "postgress_not_running"; fi;')"

	if [[ "$isrunning" = "postgress_not_running" ]]
	then
		echo "[ERROR] Postgres not running on the master. Exiting..";
        exit 1

	elif [[ "$isrunning" = "postgres_running" ]]
	then
		echo "[OK] Postgres master running on remote host";

	elif echo "[ERROR] Unexpected response. Exiting.."
	then
		exit 1
	fi
}

#Check if the supposed master is actually a master
CheckIfMasterIsActuallyAMaster () {
    ismaster="$(ssh postgres@"$1" 'if [ -f /home/postgres/data/recovery.done ]; then echo "postgres_is_a_master_instance"; else echo "postgres_is_not_master"; fi;')"
    ismaster2="$(ssh postgres@"$1" 'if [ -f /tmp/trigger_file ]; then echo "postgres_is_a_master_instance"; else echo "postgres_is_not_master"; fi;')"

    if [[ "$ismaster" = "postgres_is_not_master" && "$ismaster2" = "postgres_is_not_master" ]]
    then
        echo "[ERROR] Postgres is already running as a slave. Exiting..";
        exit 1
    elif [[ "$ismaster" = "postgres_is_a_master_instance" || "$ismaster2" = "postgres_is_a_master_instance" ]]
    then
		if [[ "$ismaster2" = "postgres_is_a_master_instance" ]]
		then
			ssh root@"$1" "rm /tmp/trigger_file"
			ssh postgres@"$1" "mv /home/postgres/data/recovery.conf /home/postgres/data/recovery.done"
		fi
        echo "[INFO] Postgres is running as master (probably)";
    elif echo "[ERROR] Unexpected response. Exiting.."
    then
        exit 1
    fi
}

#prepare local server to become the new slave server.
PrepareLocalServer () {

    if [ -f '/tmp/trigger_file' ]
    then
            rm /tmp/trigger_file
    fi
    echo "[INFO] Stopping slave node.."
    bash /etc/init.d/postgresql-9.1 stop

    if [[ -f "$datadir/recovery.done" ]];
    then
            sudo -u postgres -H mv "$datadir"/recovery.done "$datadir"/recovery.conf
    fi 

    #Remove old WAL logs
    rm /home/postgres/archive/*
}


CheckForRecoveryConfig () {
    if [[ -f "$datadir/recovery.conf" ]];
    then
        echo "[OK] Slave config file found, Continuing.."
    else
        echo "[ERROR] recovery.conf not found. Postgres is not a slave. Exiting.."
        exit 1
    fi
}


#Put master into backup mode
#Before doing PutMasterIntoBackupMode clean up archive logs (IE rm or mv /var/lib/postgresql/9.1/archive/*). They are not needed since we are effectivly createing a new base backup and then synching it.
PutMasterIntoBackupMode () {
    echo "[INFO] Putting postgres master '$1' in backup mode."
    ssh postgres@"$1" "rm /home/postgres/archive/*"
    ssh postgres@"$1" "psql -c \"SELECT pg_start_backup('Streaming Replication', true)\" postgres"
}

#rsync master's data to local postgres dir
RsyncWhileLive () {
    echo "[INFO] Transfering data from master '$1' ..."
    sudo -u postgres -H rsync -C -av --delete --progress -e ssh --exclude server.key --exclude server.crt --exclude recovery.conf --exclude postgresql.conf.master --exclude postgresql.conf.slave  --exclude postgresql.conf --exclude recovery.done --exclude postmaster.pid --exclude pg_xlog/ "$1":"$datadir"/ "$datadir"/ > /dev/null
    if [ $? == 0 ]
    then
        echo "[OK] Transfert completed.";
    else
	echo "[ERROR] Error during transfer !";
	exit 0;
    fi
}


#This archives the WAL log (ends writing to it and moves it to the $archive dir
StopBackupModeAndArchiveIntoWallLog () {
    echo "[INFO] Disable backup mode from master '$1'."
    ssh postgres@"$1" "psql -c \"SELECT pg_stop_backup()\" postgres"
    echo "[INFO] Synchronising master/slave archive directory..."
    sudo -u postgres -H rsync -C -a --progress -e ssh "$1":"$archivedir"/ "$archivedirdest"/ > /dev/null
    if [ $? == 0 ]
    then
        echo "[OK] Sync achieved.";
    else
        echo "[ERROR] Error during sync !";
        exit 0;
    fi
}

#stop postgres and copy transactions made during the last two rsync's
StopPostgreSqlAndFinishRsync () {
    echo "[INFO] Stopping master node.."
    ssh root@"$1" "/etc/init.d/postgresql-9.1 stop"
    echo "[INFO] Transfering xlog files from master... "
    sudo -u postgres -H rsync -av --delete --progress -e ssh "$sourcehost":"$datadir"/pg_xlog/ "$datadir"/pg_xlog/ > /dev/null
    if [ $? == 0 ]
    then
        echo "[OK] Transfert completed.";
    else
        echo "[ERROR] Error during transfer !";
        exit 0;
    fi
}

#Start both Master and Slave
StartLocalAndThenRemotePostGreSql () {
    echo "[INFO] Starting slave node.."
	sudo -u postgres -H cp /home/postgres/data/postgresql.conf.slave /home/postgres/data/postgresql.conf
    /etc/init.d/postgresql-9.1 start
    if ! killall -0 postmaster; then echo '[ERROR] Slave not running !'; else echo "[OK] Slave started."; fi;


    echo "[INFO] Starting master node.."
    ssh root@"$1" "/etc/init.d/postgresql-9.1 start"
    
    status=$(ssh  postgres@$1 "if ! killall -0 postmaster; then echo 'error'; else echo 'running'; fi;")
    if [ $status == "error" ]
    then
        echo "[ERROR] Master not running !";
        exit 0;
    else
        echo "[OK] Master started.";
    fi
}

#Execute above operations
Whoami
CheckIfPostgresIsRunningOnRemoteHost "$1"
CheckIfMasterIsActuallyAMaster "$1"
PrepareLocalServer "$datadir"
CheckForRecoveryConfig "$datadir"
PutMasterIntoBackupMode "$1"
RsyncWhileLive "$1"
StopBackupModeAndArchiveIntoWallLog "$1" "$archivedir" "$archivedirdest"
StopPostgreSqlAndFinishRsync "$1"
StartLocalAndThenRemotePostGreSql "$1"
