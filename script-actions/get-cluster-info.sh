#!/usr/bin/env bash

###########################################################################################################
# Script Name: get-cluster-info.sh
# Author: Vijay Thakorlal
#
# Description: This script obtains cluster information which is then displayed as part of the motd.
#
#
#
# To Do:
#
#
##########################################################################################################



#---BEGIN FUNCTIONS---


function get_active_ambari_host()
{
        USERID=$1
        PASSWD=$2
        HOST1="hn0-$(hostname |cut -d"-" -f2- )"
        HOST2="hn1-$(hostname |cut -d"-" -f2- )"

        http_response=$(curl -i --write-out %{http_code} --output /dev/null --silent "http://${HOST1}:8080")
        if [[ "$http_response" -ge 200 && "$http_response" -le 299 ]]; then
                echo $HOST1
        else
                echo $HOST2
        fi
}
#end function get_active_ambari_host()


#---END FUNCTIONS---



#---BEGIN MAIN PROGRAM---


AMBARICONFIGS_SH=/var/lib/ambari-server/resources/scripts/configs.sh

# Get credentials to use in connecting to Ambari REST API
USERID=$(sudo python -c "import hdinsight_common.Constants as Constants;print Constants.AMBARI_WATCHDOG_USERNAME")
PASSWD=$(sudo python -c "import hdinsight_common.ClusterManifestParser as ClusterManifestParser;import hdinsight_common.Constants as Constants;import base64;base64pwd = ClusterManifestParser.parse_local_manifest().ambari_users.usersmap[Constants.AMBARI_WATCHDOG_USERNAME].password;print base64.b64decode(base64pwd)" 2> /dev/null)

#echo "$USERID:$PASSWD"

# Get cluster name and type (e.g. Spark, Hadoop, Kafka)
CLUSTERNAME=$(python -c "import hdinsight_common.ClusterManifestParser as ClusterManifestParser; print ClusterManifestParser.parse_local_manifest().deployment.cluster_name;" 2> /dev/null)
CLUSTER_TYPE=$(python -c "import hdinsight_common.ClusterManifestParser as ClusterManifestParser; print ClusterManifestParser.parse_local_manifest().settings['cluster_type'];" 2> /dev/null)

# Get namenodes
NAMENODE1=$(bash "$AMBARICONFIGS_SH" -u "$USERID" -p "$PASSWD" get "$ACTIVEAMBARIHOST" "$CLUSTERNAME" hdfs-site | grep nn1 | grep https | cut -d":" -f2 | tr -d ' "')
NAMENODE2=$(bash "$AMBARICONFIGS_SH" -u "$USERID" -p "$PASSWD" get "$ACTIVEAMBARIHOST" "$CLUSTERNAME" hdfs-site | grep nn2 | grep https | cut -d":" -f2 | tr -d ' "')

ACTIVEAMBARIHOST=$(get_active_ambari_host $USERID $PASSWD)

coreSiteContent=$(bash "$AMBARICONFIGS_SH" -u "$USERID" -p "$PASSWD" get "$ACTIVEAMBARIHOST" "$CLUSTERNAME" core-site)
hdfsSiteContent=$(bash "$AMBARICONFIGS_SH" -u "$USERID" -p "$PASSWD" get "$ACTIVEAMBARIHOST" "$CLUSTERNAME" hdfs-site)

# Get storage accounts
STORAGE_ACCOUNT_LIST=$(bash "$AMBARICONFIGS_SH" -u "$USERID" -p "$PASSWD" get "$ACTIVEAMBARIHOST" "$CLUSTERNAME" core-site | grep 'blob.core' |  grep keyprovider | cut -d":" -f1 | tr -d '"','' | sed "s/fs.azure.account.keyprovider.//g")

#fs default storage account
DEFAULT_STORAGE_ACCOUNT=$(bash "$AMBARICONFIGS_SH" -u "$USERID" -p "$PASSWD" get "$ACTIVEAMBARIHOST" "$CLUSTERNAME" core-site | grep 'blob.core' |  grep 'fs.default' | awk '{print $3}'  |  tr -d '",','')

# Get HDFS trash interval
TRASH_INTERVAL=$(bash "$AMBARICONFIGS_SH" -u "$USERID" -p "$PASSWD" get "$ACTIVEAMBARIHOST" "$CLUSTERNAME" core-site | grep trash | cut -d":" -f2 | tr -d '"','')
TRASH_INTERVAL=$(python -c "print ${TRASH_INTERVAL}/60")

# Get head nodes
HEADNODE1=$(bash "$AMBARICONFIGS_SH" -u "$USERID" -p "$PASSWD" get "$ACTIVEAMBARIHOST" "$CLUSTERNAME" yarn-site | grep 'yarn.resourcemanager.hostname.rm1' | cut -d":" -f2 | tr -d '"','',' ')
HEADNODE2=$(bash "$AMBARICONFIGS_SH" -u "$USERID" -p "$PASSWD" get "$ACTIVEAMBARIHOST" "$CLUSTERNAME" yarn-site | grep 'yarn.resourcemanager.hostname.rm2' | cut -d":" -f2 | tr -d '"','',' ')

#worker nodes
#cat /etc/hadoop/conf/slaves
#cat /etc/hadoop/conf/topology_mappings.data

# yarn history server url
YARN_HISTORY_SERVER_URL=$(bash "$AMBARICONFIGS_SH" -u "$USERID" -p "$PASSWD" get "$ACTIVEAMBARIHOST" "$CLUSTERNAME" yarn-site | grep 'yarn.log.server.url' | cut -d" " -f3 | tr -d '"','')

# oozie url
OOZIE_URL=$(bash "$AMBARICONFIGS_SH" -u "$USERID" -p "$PASSWD" get "$ACTIVEAMBARIHOST" "$CLUSTERNAME" oozie-site | grep 'oozie.base.url' | cut -d":" -f2- | tr -d '"','')

# Zeppelin host and port
ZEPPELIN_PORT=$(bash "$AMBARICONFIGS_SH" -u "$USERID" -p "$PASSWD" get "$ACTIVEAMBARIHOST" "$CLUSTERNAME" zeppelin-config | grep 'zeppelin.server.port' | cut -d":" -f2  | tr -d '"','',' ')
ZEPPELIN_HOST=$(curl -u "$USERID":"$PASSWD" -sS -G "http://$ACTIVEAMBARIHOST:8080/api/v1/clusters/$CLUSTERNAME/services/ZEPPELIN" | grep 'host_name' | cut -d":" -f2 | tr -d '"','',' ')

# Jupyter
JUPYTER_HOST=$(curl -u "$USERID":"$PASSWD" -sS -G "http://$ACTIVEAMBARIHOST:8080/api/v1/clusters/$CLUSTERNAME/services/JUPYTER/components/JUPYTER_MASTER" | grep 'host_name' | cut -d":" -f2 | tr -d '"','',' ')
JUPYTER_PORT=8001

# All cluster nodes
CLUSTER_NODES=$(curl -u "$USERID":"$PASSWD" -sS -G "http://$ACTIVEAMBARIHOST:8080/api/v1/clusters/$CLUSTERNAME/hosts" | grep 'host_name' | cut -d":" -f2 | tr -d '"','')

# Cluster users
CLUSTER_USERS=$(curl -u "$USERID":"$PASSWD" -sS -G "http://$ACTIVEAMBARIHOST:8080/api/v1/users" | grep 'user_name' | cut -d":" -f2 | tr -d '"','')

# Determine Hue host
HUE_PORT=8888
HTTP_RESPONSE=$(curl --write-out "HTTPSTATUS:%{http_code}" --output /dev/null -sS -G "http://${HEADNODE1}:${HUE_PORT}")
# extract the status
HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
					
if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 302 ]]; then
	HUE_HOST=$HEADNODE1
else 
	HUE_HOST=$HEADNODE2
fi	

# Determine Solr host
SOLR_PORT=8983
HTTP_STATUS=$(curl --write-out %{http_code} --output /dev/null -sS -G "http://${HEADNODE1}:${SOLR_PORT}/solr")
# extract the status
HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -le 302 ]]; then
	SOLR_HOST=$HEADNODE1
else 
	SOLR_HOST=$HEADNODE2
fi	


cat <<EOF

CLUSTER NAME: ${CLUSTERNAME}
CLUSTER TYPE: ${CLUSTER_TYPE}

CLUSTER NODES: 
${CLUSTER_NODES}

hn: head nodes
wn: worker nodes
zk: zookeeper nodes
ed: edge nodees

YARN_HISTORY SERVER URL: ${YARN_HISTORY_SERVER_URL}
OOZIE URL: ${OOZIE_URL}
ZEPPELIN URL: http://${ZEPPELIN_HOST}:${ZEPPELIN_PORT}
JUPYTER URL: http://${JUPYTER_HOST}:${JUPYTER_PORT}
HUE URL:  http://${HUE_HOST}:${HUE_PORT}
SOLR URL: http://${SOLR_HOST}:${SOLR_PORT}

STORAGE ACCOUNT LIST: 
${STORAGE_ACCOUNT_LIST}

DEFAULT STORAGE ACCOUNT: ${DEFAULT_STORAGE_ACCOUNT}

HDFS TRASH INTERVAL IN MINS: ${TRASH_INTERVAL}

EOF


exit 0


#---END MAIN PROGRAM---
