#!/usr/bin/env bash


########################################################################################################
# Script Name: create-user-hive-dbs.sh
# Author: Vijay Thakorlal
#
# Description: This script is called by a script action and creates user specific databases using 
# HiveQL.
# 
# To Do: 
#	Consider adding the ability to specify a custom path for the databases on HDFS
#	
#
# ./create-user-hive-dbs.sh -b hdiadmin
#
########################################################################################################


#---BEGIN GLOBAL VARIABLES---

readonly SCRIPT_NAME=$(basename "$0")
SERVER=$(hostname -s)
LOGDIR=/var/custom-script-logs
LOGFILE=$LOGDIR/$SCRIPT_NAME-$SERVER.log
if [ ! -e "$LOGDIR" ] ; then
    mkdir "$LOGDIR"
fi

/bin/touch "$LOGFILE"

BEELINE='/usr/bin/beeline'

# For now this can be anything since the cluster is not kerberised 
# but later we should take this in as a parameter
BEELINE_USER=''


AMBARICONFIGS_SH=/var/lib/ambari-server/resources/scripts/configs.sh


#---END GLOBAL VARIABLES---



#---BEGIN FUNCTIONS---


# Uses the logger command to log messages to syslog and tees the same message to a file
function log()
{
  echo "$@"
  echo "$@" | tee -a "$LOGFILE" | logger -i "$SCRIPT_NAME" -p user.notice 
}
#end function log

# Uses the logger command to log error messages to syslog and tees the same message to a file
function err()
{
  echo "$@" >&2
  echo "$@" | tee -a "$LOGFILE" | logger -i "$SCRIPT_NAME" -p user.error 
}
#end function err

usage() {
	echo "
Usage: $0
  --help				Display this help message
  -b, --beelineuser     The username to use when connecting via beelineuser
  
	#Example:
	#$0 -b beelineuser	
 "
}
#end function usage()


function validate_ret () 
{
  ret=$1
  if [[ ${ret} != "" && ${ret} -ne 0 ]]; then
    err "ERROR!! when running query in bulk mode"
    exit $ret
  fi
}
#end functoin validate_ret

function generate_random_string()
{
    string_length=$1
    # We use hex as using base64 will produce non-alphanumeric characters which causes problems
    # when we use this as part of a file name
    openssl rand -hex "$string_length"
}
#end function generate_random_string


function get_active_ambari_host()
{
        USERID=$1
        PASSWD=$2
        HOST1="hn0-$(hostname |cut -d"-" -f2- )"
        HOST2="hn1-$(hostname |cut -d"-" -f2- )"

        HTTP_RESPONSE=$(curl -i --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent "http://${HOST1}:8080")
		# extract the status
		HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

        if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
                echo $HOST1
        else
                echo $HOST2
        fi
}
#end function get_active_ambari_host()


#---END FUNCTIONS---


#---BEGIN PARSE INPUT---


get_options() {
    for OPT in "$@"
    do
        case "$OPT" in
            '--help' )
                usage
                exit 1
                ;;
            '-b'|'--beelineuser' )
                    BEELINE_USER="$2"
                    shift 1
                ;;
        esac
    done
}

get_options "$@"

if [ $# -ne 2 ] || [ -z "${BEELINE_USER// }" ]; then
        err "Error wrong number of arguments specified. Terminating the script."
        usage
        exit 1
fi

log "No of script arguments: ${#}"
log "Users passwed to script: ${USERS}"
log "Beeline User passed to script: ${BEELINE_USER}"

#---END PARSE INPUT---


#---BEGIN MAIN PROGRAM---

# Only run this script on the first head node in the cluster
shorthostname=`hostname -s`
if [[  $shorthostname == headnode0* || $shorthostname == hn0* ]]; then

	USERID=$(sudo python -c "import hdinsight_common.Constants as Constants;print Constants.AMBARI_WATCHDOG_USERNAME")
	PASSWD=$(sudo python -c "import hdinsight_common.ClusterManifestParser as ClusterManifestParser;import hdinsight_common.Constants as Constants;import base64;base64pwd = ClusterManifestParser.parse_local_manifest().ambari_users.usersmap[Constants.AMBARI_WATCHDOG_USERNAME].password;print base64.b64decode(base64pwd)")

	CLUSTERNAME=$(python -c "import hdinsight_common.ClusterManifestParser as ClusterManifestParser; print ClusterManifestParser.parse_local_manifest().deployment.cluster_name;")

	ACTIVEAMBARIHOST=$(get_active_ambari_host $USERID $PASSWD)

	# Retrieve the ZooKeeper nodes in the cluster - we will use this to discover how to connect to Hive, instead of hard coding this information
	ZKHOSTS=`grep -R zk /etc/hadoop/conf/yarn-site.xml | grep 2181 | grep -oPm1 "(?<=<value>)[^<]+"`

	#storage accounts
	STORAGE_ACCOUNT_LIST=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD get $ACTIVEAMBARIHOST $CLUSTERNAME core-site | grep 'blob.core' |  grep keyprovider | cut -d":" -f1 | tr -d '"','' | sed "s/fs.azure.account.keyprovider.//g")
	
	log "Retrieved storage account list $STORAGE_ACCOUNT_LIST"

	for STORAGE_ACCOUNT in $STORAGE_ACCOUNT_LIST; do
	  if [ $(echo $STORAGE_ACCOUNT | grep artifacts ) ]; then
	   SCRIPT_STORAGE_ACCOUNT=$STORAGE_ACCOUNT
	  fi
	done

	if [ -z "${SCRIPT_STORAGE_ACCOUNT// }" ]; then
		err "Error unable to find artifacts storage account, exiting"
		exit 1
	fi

	log "Storage account containing user list: wasbs://scripts@${SCRIPT_STORAGE_ACCOUNT}/"

	DB_LIST_FILENAME="$CLUSTERNAME-user-db-list.csv"

	# Delete the file if it already exists
	[ -e "/tmp/${DB_LIST_FILENAME}" ] && rm "/tmp/${DB_LIST_FILENAME}"

	echo $USER_LIST_FILENAME

	hdfs dfs -test -e "wasbs://scripts@${SCRIPT_STORAGE_ACCOUNT}/${DB_LIST_FILENAME}"
	if [ $? != 0 ]; then
		err "Error the user db list file does not exist on HDFS at the expected location wasbs://scripts@${SCRIPT_STORAGE_ACCOUNT}/${DB_LIST_FILENAME}"
		exit 1
	fi

	log "Copying user db list from Azure storage (wasbs://scripts@${SCRIPT_STORAGE_ACCOUNT}/${DB_LIST_FILENAME}) to local file system /tmp"
	hdfs dfs -copyToLocal "wasbs://scripts@${SCRIPT_STORAGE_ACCOUNT}/${DB_LIST_FILENAME}" /tmp/

	HIVE_QL_SCRIPT="/tmp/create-user-hive-dbs-$(generate_random_string 4).sh"
	echo "" > "${HIVE_QL_SCRIPT}"

	OLDIFS=$IFS
	while IFS=, read dbname
	do	
		if [ ! "$dbname" == "dbname" ]; then
			echo "CSV LINE:$dbname"
			
			if [ -z "$dbname" ]; then
				log "The user db list CSV file does not contain the expected columns or a field is empty."
			else
				echo "CREATE DATABASE IF NOT EXISTS ${dbname};" >> "${HIVE_QL_SCRIPT}"
				echo "ALTER DATABASE ${dbname} SET OWNER USER ${dbname};" >> "${HIVE_QL_SCRIPT}"
			fi
		fi
		
	done < "/tmp/${DB_LIST_FILENAME}"
	IFS=$OLDIFS
	
	echo "SHOW DATABASES;" >> "${HIVE_QL_SCRIPT}" 

	log "Creating user database in Hive using HiveQL script ${HIVE_QL_SCRIPT}"
	$BEELINE -u "jdbc:hive2://${ZKHOSTS}/;serviceDiscoveryMode=zookeeper;zooKeeperNameSpace=hiveserver2" -n "$BEELINE_USER" -f "${HIVE_QL_SCRIPT}" 
	validate_ret $?

	# Remove the HQL script
	[ -e "${HIVE_QL_SCRIPT}" ] && rm "${HIVE_QL_SCRIPT}"

else
	# We don;t exit 1 (error) because this would then cause cluster provisioning to fail
	err "Error this script action should be run from the head node"
	exit 0
fi


exit 0

#---END MAIN PROGRAM---
