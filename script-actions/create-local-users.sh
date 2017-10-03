#!/usr/bin/env bash


########################################################################################################
# Script Name: create_local_users.sh
# Author: Vijay Thakorlal
#
# Description: Create local accounts for users on a HDInsight cluster and in Ambari
# 
# To Do: 
#	split OS and Ambari account creation into two separate scripts
#	pass storage account name container name as a parameter
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

SudoGroup='AdminUsers'

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
  
	#Example:
	#./$0

 "
}
#end function usage()


function check_if_user_already_exists()
{
	sudo getent passwd $1
}
#end function check_if_user_already_exists

function check_if_group_already_exists()
{
	sudo getent group $1
}
#end function check_if_group_already_exists

function create_sudoers_file()
{
grep $SudoGroup /etc/group &> /dev/null
if [ $? == 0 ]; then
	log "$SudoGroup group already exists, skipping step"
else
	log "Creating group $SudoGroup "
	groupadd $SudoGroup

	SudoersFile='xSudoConfig'
	if [ -f /etc/sudoers.d/"$SudoersFile" ]
	then
		log "Sudoers file already exists, skipping step."
	else
		log "%AdminUsers ALL = (ALL) ALL" > "/tmp/$SudoersFile"

		chown root:root "/tmp/$SudoersFile"
		chmod 0440 "/tmp/$SudoersFile"

		log 'checking sudoers file to be placed under /etc/sudoers.d/'
		RET=$(/usr/sbin/visudo -c -f "/tmp/$SudoersFile")
		if [ "$RET" == "/tmp/$SudoersFile: parsed OK" ]; then
			log "sudoers file is OK, moving to /etc/sudoers.d/ "
			mv "/tmp/$SudoersFile" "/etc/sudoers.d/$SudoersFile"
		else
			log "sudoers file NOT OK. This part will have to be completed manually."
		fi
	fi
fi
}
# end function create_sudoers_file

function check_ambari_user_exists()
{
        USER_TO_CHECK=$1
        # Get list of users in Ambari
        USER_LIST=$(curl -u "$USERID:$PASSWD" -sS -G "http://${ACTIVEAMBARIHOST}:8080/api/v1/users" | grep 'user_name' | cut -d":" -f2 | tr -d '"','',' ' )
        for User in $( echo "$USER_LIST" | tr '\r' ' '); do
                echo "-${User}-"
                if [  "$User" == "$USER_TO_CHECK" ];then
                        echo 0
						return
                fi
        done
        # the user does not exist
        echo 1
}
#end function check_ambari_user_exists

function check_ambari_group_exists()
{
	GROUP_TO_CHECK=$1

	# store the whole response with the status at the and
	HTTP_RESPONSE=$(curl -u "$USERID:$PASSWD" --silent --write-out "HTTPSTATUS:%{http_code}" -G "http://${ACTIVEAMBARIHOST}:8080/api/v1/groups")

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	#http_response=$(curl -u "$USERID:$PASSWD" -sS -G "http://${ACTIVEAMBARIHOST}:8080/api/v1/groups" | grep 'group_name' | cut -d":" -f2 | tr -d '"','',' ' )
	
	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		# Get list of groups in Ambari
		IFS=$'\n'
		GROUP_LIST=$(curl -u "$USERID:$PASSWD" -sS -G "http://${ACTIVEAMBARIHOST}:8080/api/v1/groups" | grep 'group_name' | cut -d":" -f2 | tr -d '"','',' ' )
		unset IFS
		for GROUP in "$GROUP_LIST"; do
			#echo "$GROUP"
			if [  "$GROUP" == "$GROUP_TO_CHECK" ];then
				echo 0 
				return
			fi
		done
	else
		echo 1
		return
	fi
		
	# the group does not exist
	echo 1
}
#end function check_ambari_group_exists

function check_user_is_member_of_ambari_group()
{
	USER_TO_CHECK=$1
	GROUP_TO_CHECK=$2
	
	# store the whole response with the status at the and
	HTTP_RESPONSE=$(curl -u "$USERID:$PASSWD" --silent --write-out "HTTPSTATUS:%{http_code}" -G "http://${ACTIVEAMBARIHOST}:8080/api/v1/groups/${GROUP_TO_CHECK}/members")

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	#http_response=$(curl -u "$USERID:$PASSWD" -sS -G "http://${ACTIVEAMBARIHOST}:8080/api/v1/groups/${GROUP_TO_CHECK}/members" | grep 'user_name' | cut -d":" -f2 | tr -d '"','',' ' )
	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		# Get members of the group
		IFS=$'\n'
		USER_LIST=$(curl -u "$USERID:$PASSWD" -sS -G "http://${ACTIVEAMBARIHOST}:8080/api/v1/groups/${GROUP_TO_CHECK}/members" | grep 'user_name' | cut -d":" -f2 | tr -d '"','',' ' )
		unset IFS
		for User in "$USER_LIST"; do
			#echo "$User"
			if [  "$User" == "$USER_TO_CHECK" ];then
				echo 0
				return
			fi
		done	
	else 
		echo 1
		return
	fi
		
	# the user is not a member of the specified group
	echo 1
}
#end function check_ambari_group_exists

function mark_as_staff_in_hue()
{
	USERNAME=$1
/usr/share/hue/build/env/bin/hue shell <<EOF
from django.contrib.auth.models import User
a = User.objects.get(username='$USERNAME')
a.is_staff = True
a.save()
quit()

EOF

}
#end function mark_as_admin_in_hue()

# This function will mark the user as admin and staff in Hue
function mark_as_admin_in_hue()
{
	USERNAME=$1
/usr/share/hue/build/env/bin/hue shell <<EOF
from django.contrib.auth.models import User
a = User.objects.get(username='$USERNAME')
a.is_staff = True
a.is_superuser = True
a.save()
quit()

EOF

}
#end function mark_as_admin_in_hue()

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

#---END PARSE INPUT---


#---BEGIN MAIN PROGRAM---


AMBARICONFIGS_SH=/var/lib/ambari-server/resources/scripts/configs.sh

# Get the watchdog username and password, we will use this account to create the users and groups in Ambari
USERID=$(sudo python -c "import hdinsight_common.Constants as Constants;print Constants.AMBARI_WATCHDOG_USERNAME")
PASSWD=$(sudo python -c "import hdinsight_common.ClusterManifestParser as ClusterManifestParser;import hdinsight_common.Constants as Constants;import base64;base64pwd = ClusterManifestParser.parse_local_manifest().ambari_users.usersmap[Constants.AMBARI_WATCHDOG_USERNAME].password;print base64.b64decode(base64pwd)")

#echo "$USERID:$PASSWD"

# Get the cluster name
CLUSTERNAME=$(python -c "import hdinsight_common.ClusterManifestParser as ClusterManifestParser; print ClusterManifestParser.parse_local_manifest().deployment.cluster_name;")
# Get the active Ambari host (we need to do this because the node that Ambari runs on can change if it fails over to a different head node)
ACTIVEAMBARIHOST=$(get_active_ambari_host $USERID $PASSWD)

# Get a list of storage accounts
STORAGE_ACCOUNT_LIST=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD get $ACTIVEAMBARIHOST $CLUSTERNAME core-site | grep 'blob.core' |  grep keyprovider | cut -d":" -f1 | tr -d '"','' | sed "s/fs.azure.account.keyprovider.//g")

log "Retrieved storage account list $STORAGE_ACCOUNT_LIST"

for STORAGE_ACCOUNT in $STORAGE_ACCOUNT_LIST; do
  if [ $(echo $STORAGE_ACCOUNT | grep artifacts ) ]; then
   SCRIPT_STORAGE_ACCOUNT=$STORAGE_ACCOUNT
  fi
done

if [ -z "${SCRIPT_STORAGE_ACCOUNT// }" ]; then
	log "Error unable to find artifacts storage account, exiting"
	exit 1
fi

log "Storage account containing user list: wasbs://scripts@${SCRIPT_STORAGE_ACCOUNT}/"

USER_LIST_FILENAME="$CLUSTERNAME-user-list.csv"

# Delete the file if it already exists
[ -e "/tmp/${USER_LIST_FILENAME}" ] && rm "/tmp/${USER_LIST_FILENAME}"

echo $USER_LIST_FILENAME
#hdfs dfs -ls "wasbs://scripts@${SCRIPT_STORAGE_ACCOUNT}/${USER_LIST_FILENAME}"

hdfs dfs -test -e "wasbs://scripts@${SCRIPT_STORAGE_ACCOUNT}/${USER_LIST_FILENAME}"
if [ $? != 0 ]; then
	log "Error the user list file does not exist on HDFS at the expected location wasbs://scripts@${SCRIPT_STORAGE_ACCOUNT}/${USER_LIST_FILENAME}"
	exit 1
fi

log "Copying user list from Azure storage (wasbs://scripts@${SCRIPT_STORAGE_ACCOUNT}/${USER_LIST_FILENAME}) to local file system /tmp"

hdfs dfs -copyToLocal "wasbs://scripts@${SCRIPT_STORAGE_ACCOUNT}/${USER_LIST_FILENAME}" /tmp/

# create sudoers file
create_sudoers_file

# Comment out line 504 and 505, as this causes a problem with running 
# /usr/share/hue/build/env/bin/hue useradmin_sync_with_unix
HUE_USERADMIN_PY=/usr/share/hue/apps/useradmin/src/useradmin/views.py
cp "$HUE_USERADMIN_PY" ~/"$(basename $HUE_USERADMIN_PY).backup-$(date +"%m_%d_%Y_%H%M")"
sed -i '504,505 s/^/#/' "$HUE_USERADMIN_PY"

OLDIFS=$IFS
while IFS=, read firstname lastname username uid gid userpassword osusertype ambarigroup
do	
	if [ ! "$firstname" == "firstname" ]; then
		echo "CSV LINE:$firstname|$lastname|$username|$uid|$gid|redacteduserpassword|$osusertype|$ambarigroup"
		
		if [ -z "$firstname" ] && [ -z "$lastname" ] && [ -z "$username" ] && [ -z "$uid" ] && [ -z "$gid" ] && [ -z "$userpassword" ] && [ -z "$osusertype" ] && [ -z "$ambarigroup" ]; then
			log "The user list CSV file does not contain the expected columns or a field is empty."
		else
			if [ $(check_if_user_already_exists $username) ] || [ $(check_if_group_already_exists $username) ]; then
				log "Error the user/group $username already exists at the operating system level"
			else
				log "Creating a new OS user: $username with uid $uid and gid $gid"
				log "User $username does NOT exist, creating user with the specified password "				
				useradd -m -u "$uid" -U -s /bin/bash "$username"
				if [ $? != 0 ]; then 
					log "Error unable to add a new user with the username: $username"
					exit 1
				fi
				
				echo -e "$userpassword\n$userpassword" | passwd "$username"
				if [ $? != 0 ]; then 
					log "Error changing the password for the user $username"
					exit 1
				fi

				log "Added user $username"
				
				if [ "$osusertype" == "admin" ]; then
				if groups "$username" | grep &>/dev/null "\b$SudoGroup\b"; then
					log "$username is already a member of the sudo group $SudoGroup, nothing to do."
				else
						log "Adding $USERNAME to the sudo group $SudoGroup"						
						usermod -a -G "$SudoGroup" "$username"
						if [ $? != 0 ]; then
							log "Error adding the user $username to the sudo group $SudoGroup"
							exit 1
						fi
					fi
				fi				
			fi
			
			# only run these commands once on one of the head nodes			
			if [[ "$(hostname -s)" == hn0* ]]; then			
				# Synchronise users before marking a user as staff or admin
				/usr/share/hue/build/env/bin/hue useradmin_sync_with_unix

				# If the Ambari group is clusteradministrator make the user a Hue admin too, else just mark then as staff in Hue
				if [ "$ambarigroup" == "clusteradministrator" ]; then
					mark_as_admin_in_hue "$username"
				else
					mark_as_staff_in_hue "$username"
				fi
					
				#Check if user exists in Ambari			
				if [ "$(check_ambari_user_exists "$username")" == 0 ]; then
					log "Error user ${username} already exists in Ambari"				
				else
					log "Creating ambari user ${username}"
					
					HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X POST -d "{\"Users/user_name\":\"${username}\",\"Users/password\":\"${userpassword}\",\"Users/active\":\"true\",\"Users/admin\":\"false\"}" "http://${ACTIVEAMBARIHOST}:8080/api/v1/users")
					
					# extract the status
					HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

					if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
						log "Added user ${username} to Ambari"
					else 
						log "Error occured in adding user ${username}: ${HTTP_RESPONSE}"
					fi
				fi
				
				if [ "$(check_ambari_group_exists "$ambarigroup")" == 0 ]; then
					log "Error group ${ambarigroup} already exists in Ambari"
				else
					log "Creating ambari group ${ambarigroup}"
					
					HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X POST -d "{\"Groups/group_name\":\"${ambarigroup}\"}" "http://${ACTIVEAMBARIHOST}:8080/api/v1/groups")

					# extract the status
					HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

					if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
						log "Added group ${ambarigroup} to Ambari"
					else 
						log "Error occured in adding group ${ambarigroup} to Ambari: ${HTTP_RESPONSE}"
					fi
				fi
				
				if [ "$(check_user_is_member_of_ambari_group "$username" "$ambarigroup")" == 0 ]; then
					log "Error user ${username} is already a member of the group ${ambarigroup} in Ambari"
				else
					log "Adding ${username} to the group ${ambarigroup} in Ambari"

					HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X POST -d "[{\"MemberInfo/user_name\":\"${username}\", \"MemberInfo/group_name\":\"${ambarigroup}\"}]" "http://${ACTIVEAMBARIHOST}:8080/api/v1/groups/${ambarigroup}/members")

					# extract the status
					HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

					if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
						log "Added ambari user ${username} to Ambari group ${ambarigroup}"
					else 
						log "Error occured in adding user ${username} to group ${ambarigroup} to Ambari: ${HTTP_RESPONSE}"
					fi
				fi
			fi 
			#end if [[ "$(hostname -s)" == hn0* ]]; then
		fi	
	fi
done < "/tmp/${USER_LIST_FILENAME}"
IFS=$OLDIFS


# only run these commands once on one of the head nodes			
if [[ "$(hostname -s)" == hn0* ]]; then			
			
	## ADD GROUPS TO CLUSTER AMBARI ROLES

	HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X POST -d '[{"PrivilegeInfo":{"permission_name":"CLUSTER.USER","principal_name":"clusteruser","principal_type":"GROUP"}}]' http://${ACTIVEAMBARIHOST}:8080/api/v1/clusters/${CLUSTERNAME}/privileges)

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		log "Granted clusteruser group to the CLUSTER USER Ambari role"
	else 
		log "Error occured in adding clusteruser group to the CLUSTER USER Ambari role: ${HTTP_RESPONSE}"
	fi

	HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X POST -d '[{"PrivilegeInfo":{"permission_name":"CLUSTER.ADMINISTRATOR","principal_name":"clusteradministrator","principal_type":"GROUP"}}]' http://${ACTIVEAMBARIHOST}:8080/api/v1/clusters/${CLUSTERNAME}/privileges)

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		log "Granted clusteradministrator group to the CLUSTER ADMINISTRATOR Ambari role"
	else 
		log "Error occured in adding clusteradministrator group to the CLUSTER ADMINISTRATOR Ambari role: ${HTTP_RESPONSE}"
	fi

	# Check the Pig and Oozie Views exist if not create them
	VIEWS=$(curl --user "$USERID":"$PASSWD" -i -H 'X-Requested-By: ambari' -G "http://${ACTIVEAMBARIHOST}:8080/api/v1/views" | grep 'view_name' | cut -d":" -f2 | tr -d '"','',' ')
    PIG_VIEW=1
	OOZIE_VIEW=1
	
	for view in $VIEWS; do
		echo $view
		if [ $view == "PIG" ]; then
			PIG_VIEW=0
		fi
		if [ $view == "OOZIE" ]; then
			OOZIE_VIEW=0
		fi
	done

	if [ $PIG_VIEW == 1 ]; then
		echo "Pig view does not exist, creating it"
		log "Creating Pig Ambari View"
		# Create PIG View
		curl --user "$USERID":"$PASSWD" -i -H 'X-Requested-By: ambari' -X POST "http://${ACTIVEAMBARIHOST}:8080/api/v1/views/PIG/versions/1.0.0/instances/PIG_INSTANCE1" \
--data '{
  "ViewInstanceInfo" : {
      "description" : "PIG View",
	  "cluster_type" : "LOCAL_AMBARI",
	  "cluster_handle" : 2
   }
}'
	fi
	if [ $OOZIE_VIEW == 1 ]; then
		echo "Oozie view does not exist, creating it"
		log "Creating Oozie Ambari View"
		curl --user "$USERID":"$PASSWD" -i -H 'X-Requested-By: ambari' -X POST "http://${ACTIVEAMBARIHOST}:8080/api/v1/views/Workflow%20Manager/versions/1.0.0/instances/OOZIE_INSTANCE1" \
--data '{
  "ViewInstanceInfo" : {
      "description" : "Oozie Workflow Manager",
	  "cluster_type" : "LOCAL_AMBARI",
	  "cluster_handle" : 2
   }
}'
	fi
	
	## GRANT ACCESS TO VIEWS

	# Grant access to Hive View
	HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X POST  -d  '[{"PrivilegeInfo":{"permission_name":"VIEW.USER","principal_name":"clusteruser","principal_type":"GROUP"}}]'  http://${ACTIVEAMBARIHOST}:8080/api/v1/views/HIVE/versions/1.5.0/instances/AUTO_HIVE_INSTANCE/privileges)

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		log "Granted clusteruser group access to Hive View"
	else 
		log "Error occured in granting clusteruser access to Hive View: ${HTTP_RESPONSE}"
	fi

	HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X POST  -d  '[{"PrivilegeInfo":{"permission_name":"VIEW.USER","principal_name":"clusteradministrator","principal_type":"GROUP"}}]'  http://${ACTIVEAMBARIHOST}:8080/api/v1/views/HIVE/versions/1.5.0/instances/AUTO_HIVE_INSTANCE/privileges)

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		log "Granted clusteradministrator group access to Hive View"
	else 
		log "Error occured in granting clusteradministrator access to Hive View: ${HTTP_RESPONSE}"
	fi

	# Grant access to Tez View
	HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X POST  -d  '[{"PrivilegeInfo":{"permission_name":"VIEW.USER","principal_name":"clusteruser","principal_type":"GROUP"}}]'  http://${ACTIVEAMBARIHOST}:8080/api/v1/views/TEZ/versions/1.0.0/instances/TEZ_CLUSTER_INSTANCE/privileges)

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		log "Granted clusteruser group access to Tez View"
	else 
		log "Error occured in granting clusteruser access to Tez View: ${HTTP_RESPONSE}"
	fi

	HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X POST  -d  '[{"PrivilegeInfo":{"permission_name":"VIEW.USER","principal_name":"clusteradministrator","principal_type":"GROUP"}}]'  http://${ACTIVEAMBARIHOST}:8080/api/v1/views/TEZ/versions/1.0.0/instances/TEZ_CLUSTER_INSTANCE/privileges)

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		log "Granted clusteradministrator group access to Tez View"
	else 
		log "Error occured in granting clusteradministrator access to Tez View: ${HTTP_RESPONSE}"
	fi

	# Grant access to Zeppelin View
	HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X POST  -d  '[{"PrivilegeInfo":{"permission_name":"VIEW.USER","principal_name":"clusteruser","principal_type":"GROUP"}}]'  http://${ACTIVEAMBARIHOST}:8080/api/v1/views/ZEPPELIN/versions/1.0.0/instances/AUTO_ZEPPELIN_INSTANCE/privileges)

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		log "Granted clusteruser group access to Zeppelin View"
	else 
		log "Error occured in granting clusteruser access to Zeppelin View: ${HTTP_RESPONSE}"
	fi

	HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X POST  -d  '[{"PrivilegeInfo":{"permission_name":"VIEW.USER","principal_name":"clusteradministrator","principal_type":"GROUP"}}]'  http://${ACTIVEAMBARIHOST}:8080/api/v1/views/ZEPPELIN/versions/1.0.0/instances/AUTO_ZEPPELIN_INSTANCE/privileges)

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		log "Granted clusteradministrator group access to Zeppelin View"
	else 
		log "Error occured in granting clusteradministrator access to Zeppelin View: ${HTTP_RESPONSE}"
	fi

	# Grant access to PIG View
	HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X POST  -d  '[{"PrivilegeInfo":{"permission_name":"VIEW.USER","principal_name":"clusteruser","principal_type":"GROUP"}}]'  http://${ACTIVEAMBARIHOST}:8080/api/v1/views/PIG/versions/1.0.0/instances/PIG_INSTANCE1/privileges)

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		log "Granted clusteruser group access to Pig View"
	else 
		log "Error occured in granting clusteruser access to Pig View: ${HTTP_RESPONSE}"
	fi

	HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X POST  -d  '[{"PrivilegeInfo":{"permission_name":"VIEW.USER","principal_name":"clusteradministrator","principal_type":"GROUP"}}]'  http://${ACTIVEAMBARIHOST}:8080/api/v1/views/PIG/versions/1.0.0/instances/PIG_INSTANCE1/privileges)

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		log "Granted clusteradministrator group access to Pig View"
	else 
		log "Error occured in granting clusteradministrator access to Pig View: ${HTTP_RESPONSE}"
	fi

	# Grant access to Oozie View
	HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X PUT  -d  '[{"PrivilegeInfo":{"permission_name":"VIEW.USER","principal_name":"clusteruser","principal_type":"GROUP"}}]'  http://${ACTIVEAMBARIHOST}:8080/api/v1/views/Workflow%20Manager/versions/1.0.0/instances/OOZIE_INSTANCE1/privileges)

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		log "Granted clusteruser group access to Oozie View"
	else 
		log "Error occured in granting clusteruser access to Oozie View: ${HTTP_RESPONSE}"
	fi

	HTTP_RESPONSE=$(curl -iv --write-out "HTTPSTATUS:%{http_code}" --output /dev/null --silent -u "$USERID:$PASSWD" -H "X-Requested-By: ambari" -X PUT  -d  '[{"PrivilegeInfo":{"permission_name":"VIEW.USER","principal_name":"clusteradministrator","principal_type":"GROUP"}}]'  http://${ACTIVEAMBARIHOST}:8080/api/v1/views/Workflow%20Manager/versions/1.0.0/instances/OOZIE_INSTANCE1/privileges)

	# extract the status
	HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

	if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 299 ]]; then
		log "Granted clusteradministrator group access to Oozie View"
	else 
		log "Error occured in granting clusteradministrator access to Oozie View: ${HTTP_RESPONSE}"
	fi

fi 
#end if [[ "$(hostname -s)" == hn0* ]]; then

# Delete the local file and the one on Azure storage
[ -e "/tmp/${USER_LIST_FILENAME}" ] && rm "/tmp/${USER_LIST_FILENAME}"
hdfs dfs -rm "wasbs://scripts@${SCRIPT_STORAGE_ACCOUNT}/${USER_LIST_FILENAME}"

exit 0

#---END MAIN PROGRAM---
