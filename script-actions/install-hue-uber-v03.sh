#!/usr/bin/env bash

# This is a version of the script published here https://github.com/Azure/azure-content/blob/master/articles/hdinsight/hdinsight-hadoop-customize-cluster-linux.md that installs Hue on a HDInsight cluster.
# However the script published by MSFT does not work on HDInsight 3.5 clusters mainly due to the fact that with HDI 3.5 the Operating System has been upgraded from Ubuntu 14.04.5 LTS to Ubuntu 16.04.1 LTS; one of the changes is that 16.x now uses systemd instead of Upstart for its init system. The original MSFT script only supports Upstart.


#---BEGIN GLOBAL VARIABLES---

readonly SCRIPT_NAME=$(basename "$0")

CORESITEPATH=/etc/hadoop/conf/core-site.xml
AMBARICONFIGS_SH=/var/lib/ambari-server/resources/scripts/configs.sh
PORT=8080

WEBWASB_TARFILE=webwasb-tomcat.tar.gz
WEBWASB_TARFILEURI=https://hdiconfigactions.blob.core.windows.net/linuxhueconfigactionv01/$WEBWASB_TARFILE
WEBWASB_TMPFOLDER=/tmp/webwasb
WEBWASB_INSTALLFOLDER=/usr/share/webwasb-tomcat

HUE_TARFILE=hue-binaries.tgz

# Systemd service file for webwasb
WEBWASB_SYSTEMD_SERVICE_FILE=/etc/systemd/system/webwasb.service
HUE_SYSTEMD_SERVICE_FILE=/etc/systemd/system/hue.service

OS_VERSION=$(lsb_release -sr)

JAVA_HOME=$(update-java-alternatives -l | awk '{print $3}')

if [[ $OS_VERSION == 14* ]]; then
    echo "OS verion is $OS_VERSION. Using hue-binaries-14-04."
    HUE_TARFILE=hue-binaries-14-04.tgz
elif [[ $OS_VERSION == 16* ]]; then
    echo "OS verion is $OS_VERSION. Using hue-binaries-16-04."
    HUE_TARFILE=hue-binaries-16-04.tgz
fi

HUE_TARFILEURI=https://hdiconfigactions.blob.core.windows.net/linuxhueconfigactionv01/$HUE_TARFILE
HUE_TMPFOLDER=/tmp/hue
HUE_INSTALLFOLDER=/usr/share/hue
HUE_INIPATH=$HUE_INSTALLFOLDER/desktop/conf/hue.ini
ACTIVEAMBARIHOST=headnodehost


#---END GLOBAL VARIABLES---


#---BEGIN FUNCTIONS---


usage() {
    echo ""
    echo "Usage: sudo -E bash $SCRIPT_NAME ";
    echo "This script does NOT require Ambari username and password";
    exit 132;
}

checkHostNameAndSetClusterName() {
    fullHostName=$(hostname -f)
    echo "fullHostName=$fullHostName"
    if [[ $fullHostName != headnode0* && $fullHostName != hn0* ]]; then
        echo "$fullHostName is not headnode 0. This script has to be run on headnode0."
        exit 0
    fi
    CLUSTERNAME=$(sed -n -e 's/.*\.\(.*\)-ssh.*/\1/p' <<< $fullHostName)
    if [ -z "$CLUSTERNAME" ]; then
        CLUSTERNAME=$(echo -e "import hdinsight_common.ClusterManifestParser as ClusterManifestParser\nprint ClusterManifestParser.parse_local_manifest().deployment.cluster_name" | python)
        if [ $? -ne 0 ]; then
            echo "[ERROR] Cannot determine cluster name. Exiting!"
            exit 133
        fi
    fi
    echo "Cluster Name=$CLUSTERNAME"
}

validateUsernameAndPassword() {
    coreSiteContent=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD get $ACTIVEAMBARIHOST $CLUSTERNAME core-site)
    if [[ $coreSiteContent == *"[ERROR]"* && $coreSiteContent == *"Bad credentials"* ]]; then
        echo "[ERROR] Username and password are invalid. Exiting!"
        exit 134
    fi
}

updateAmbariConfigs() {
    updateResult=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD set $ACTIVEAMBARIHOST $CLUSTERNAME core-site "hadoop.proxyuser.oozie.groups" "*")
    
    if [[ $updateResult != *"Tag:version"* ]] && [[ $updateResult == *"[ERROR]"* ]]; then
        echo "[ERROR] Failed to update core-site. Exiting!"
        echo $updateResult
        exit 135
    fi
    
    echo "Updated hadoop.proxyuser.hue.groups = *"
    
    updateResult=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD set $ACTIVEAMBARIHOST $CLUSTERNAME oozie-site "oozie.service.ProxyUserService.proxyuser.hue.hosts" "*")
    
    if [[ $updateResult != *"Tag:version"* ]] && [[ $updateResult == *"[ERROR]"* ]]; then
        echo "[ERROR] Failed to update oozie-site. Exiting!"
        echo $updateResult
        exit 135
    fi
    
    echo "Updated oozie.service.ProxyUserService.proxyuser.hue.hosts = *"
    
    updateResult=$(bash $AMBARICONFIGS_SH -u $USERID -p $PASSWD set $ACTIVEAMBARIHOST $CLUSTERNAME oozie-site "oozie.service.ProxyUserService.proxyuser.hue.groups" "*")
    
    if [[ $updateResult != *"Tag:version"* ]] && [[ $updateResult == *"[ERROR]"* ]]; then
        echo "[ERROR] Failed to update oozie-site. Exiting!"
        echo $updateResult
        exit 135
    fi
    
    echo "Updated oozie.service.ProxyUserService.proxyuser.hue.hosts = *"
}

stopServiceViaRest() {
    if [ -z "$1" ]; then
        echo "Need service name to stop service"
        exit 136
    fi
    SERVICENAME=$1
    echo "Stopping $SERVICENAME"
    curl -u $USERID:$PASSWD -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Stop Service for Hue installation"}, "Body": {"ServiceInfo": {"state": "INSTALLED"}}}' http://$ACTIVEAMBARIHOST:$PORT/api/v1/clusters/$CLUSTERNAME/services/$SERVICENAME
}

startServiceViaRest() {
    if [ -z "$1" ]; then
        echo "Need service name to start service"
        exit 136
    fi
    sleep 2
    SERVICENAME=$1
    echo "Starting $SERVICENAME"
    startResult=$(curl -u $USERID:$PASSWD -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Start Service for Hue installation"}, "Body": {"ServiceInfo": {"state": "STARTED"}}}' http://$ACTIVEAMBARIHOST:$PORT/api/v1/clusters/$CLUSTERNAME/services/$SERVICENAME)
    if [[ $startResult == *"500 Server Error"* || $startResult == *"internal system exception occurred"* ]]; then
        sleep 60
        echo "Retry starting $SERVICENAME"
        startResult=$(curl -u $USERID:$PASSWD -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Start Service for Hue installation"}, "Body": {"ServiceInfo": {"state": "STARTED"}}}' http://$ACTIVEAMBARIHOST:$PORT/api/v1/clusters/$CLUSTERNAME/services/$SERVICENAME)
    fi
    echo $startResult
}

downloadAndUnzipWebWasb() {
    echo "Removing WebWasb installation and tmp folder"
    rm -rf $WEBWASB_INSTALLFOLDER/
    rm -rf $WEBWASB_TMPFOLDER/
    mkdir $WEBWASB_TMPFOLDER/
    
    echo "Downloading webwasb tar file"
    wget $WEBWASB_TARFILEURI -P $WEBWASB_TMPFOLDER
    
    echo "Unzipping webwasb-tomcat"
    cd $WEBWASB_TMPFOLDER
    tar -zxvf $WEBWASB_TARFILE -C /usr/share/
    
    rm -rf $WEBWASB_TMPFOLDER/
}

setupWebWasbService() {
    echo "Adding webwasb user"
    useradd -r webwasb

if [[ $OS_VERSION == 14* ]]; then
    echo "OS verion is $OS_VERSION. Configuring upstart init file"
    echo "Making webwasb a service and start it"
    # Not sure that this does anything - as the path to the JRE seems to be hard coded in the 14.04 version of the webwasb tar.gz file
    sed -i "s|JAVAHOMEPLACEHOLDER|$JAVA_HOME|g" $WEBWASB_INSTALLFOLDER/upstart/webwasb.conf
    chown -R webwasb:webwasb $WEBWASB_INSTALLFOLDER

    cp -f $WEBWASB_INSTALLFOLDER/upstart/webwasb.conf /etc/init/
    initctl reload-configuration
    stop webwasb
    start webwasb
elif [[ $OS_VERSION == 16* ]]; then
    echo "OS verion is $OS_VERSION. Configuring systemd init file"
    touch $WEBWASB_SYSTEMD_SERVICE_FILE
    cat > $WEBWASB_SYSTEMD_SERVICE_FILE <<EOF
# Systemd unit file for Web WASB
# Reference links
# https://www.digitalocean.com/community/tutorials/how-to-install-apache-tomcat-8-on-ubuntu-14-04
# https://www.digitalocean.com/community/tutorials/how-to-install-apache-tomcat-8-on-ubuntu-16-04
[Unit]
Description=Apache Tomcat Web Application Container for Web WASB
After=syslog.target network.target

[Service]
Type=forking

User=webwasb
Group=webwasb

SyslogIdentifier=webwasb

Environment=JAVA_HOME=JAVAHOMEPLACEHOLDER
Environment=CATALINA_PID=/opt/tomcat/temp/tomcat.pid
Environment=CATALINA_HOME=/usr/share/webwasb-tomcat
Environment=CATALINE_BASE=/usr/share/webwasb-tomcat
#Environment='CATALINA_OPTS=-Xms512M -Xmx1024M -server -XX:+UseParallelGC'
Environment='JAVA_OPTS=-Djava.awt.headless=true -Djava.security.egd=file:/dev/./urandom'

ExecStart=/usr/share/webwasb-tomcat/bin/catalina.sh run
ExecStop=/usr/share/webwasb-tomcat/bin/catalina.sh stop
#ExecStop=/bin/kill -15 \$MAINPID && rm -rf \${CATALINA_HOME}/temp/*

RestartSec=30
Restart=always

[Install]
WantedBy=multi-user.target

EOF
    chown -R webwasb:webwasb $WEBWASB_INSTALLFOLDER
    touch $WEBWASB_SYSTEMD_SERVICE_FILE
    sed -i "s|JAVAHOMEPLACEHOLDER|$JAVA_HOME|g" $WEBWASB_SYSTEMD_SERVICE_FILE 

    systemctl daemon-reload
    systemctl enable webwasb.service
    systemctl start webwasb.service

fi

}

downloadAndUnzipHue() {
    echo "Removing Hue tmp folder"
    rm -rf $HUE_TMPFOLDER
    mkdir $HUE_TMPFOLDER
    
    echo "Downloading Hue tar file"
    wget $HUE_TARFILEURI -P $HUE_TMPFOLDER
    
    echo "Unzipping Hue"
    cd $HUE_TMPFOLDER
    tar -zxvf $HUE_TARFILE -C /usr/share/
    
    rm -rf $HUE_TMPFOLDER
}

setupHueService() {
    echo "Installing Hue dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -q -y install libxslt-dev
    
    echo "Configuring Hue default FS"
    defaultfsnode=$(sed -n '/<name>fs.default/,/<\/value>/p' $CORESITEPATH)
    if [ -z "$defaultfsnode" ]
      then
        echo "[ERROR] Cannot find fs.defaultFS configuration in core-site.xml. Exiting"
        exit 137
    fi

    defaultfs=$(sed -n -e 's/.*<value>\(.*\)<\/value>.*/\1/p' <<< $defaultfsnode)

    if [[ $defaultfs != wasb* ]]
      then
        echo "[ERROR] fs.defaultFS is not WASB. Exiting."
        exit 138
    fi

    sed -i "s|DEFAULTFSPLACEHOLDER|$defaultfs|g" $HUE_INIPATH
    
    headnode0hostname=`hostname`

    if [[ $headnode0hostname == hn0-* ]]; then
        hn1prefix=hn1-
        headnode1hostname=${headnode0hostname/hn0-/$hn1prefix}
        echo "headnode 0 = $headnode0hostname"
        echo "headnode 1 = $headnode1hostname"
        sed -i "s|http://headnode0:8088|http://$headnode0hostname:8088|g" $HUE_INIPATH
        sed -i "s|http://headnode1:8088|http://$headnode1hostname:8088|g" $HUE_INIPATH
    fi

    echo "Adding hue user"
    useradd -r hue
    chown -R hue:hue /usr/share/hue

    echo "Making Hue a service and start it"
    if [[ $OS_VERSION == 14* ]]; then
        echo "Configuring Hue upstart config file"
        cp $HUE_INSTALLFOLDER/upstart/hue.conf /etc/init/
        initctl reload-configuration
        stop hue
        start hue
    elif [[ $OS_VERSION == 14* ]]; then
        touch $HUE_SYSTEMD_SERVICE_FILE
    cat > $HUE_SYSTEMD_SERVICE_FILE <<EOF
# Systemd unit file for Hue
[Unit]
Description=Hue Web Interface for Apache Hadoop
After=syslog.target network.target

[Service]
Type=simple

User=hue
Group=hue

SyslogIdentifier=hue

ExecStart=/usr/share/hue/build/env/bin/supervisor
KillMode=process 
 
RestartSec=30
Restart=always

[Install]
WantedBy=multi-user.target

EOF
    systemctl daemon-reload
    systemctl enable hue.service
    systemctl start hue.service
    fi
}


#---END FUNCTIONS---


#---BEGIN MAIN PROGRAM---
if [ "$(id -u)" != "0" ]; then
    echo "[ERROR] The script has to be run as root."
    usage
fi

USERID=$(echo -e "import hdinsight_common.Constants as Constants\nprint Constants.AMBARI_WATCHDOG_USERNAME" | python)

echo "USERID=$USERID"

PASSWD=$(echo -e "import hdinsight_common.ClusterManifestParser as ClusterManifestParser\nimport hdinsight_common.Constants as Constants\nimport base64\nbase64pwd = ClusterManifestParser.parse_local_manifest().ambari_users.usersmap[Constants.AMBARI_WATCHDOG_USERNAME].password\nprint base64.b64decode(base64pwd)" | python)

export $JAVA_HOME

if [ -e $HUE_INSTALLFOLDER ]; then
    echo "Hue is already installed. Exiting ..."
    exit 0
fi

echo JAVA_HOME=$JAVA_HOME

checkHostNameAndSetClusterName
validateUsernameAndPassword
updateAmbariConfigs
stopServiceViaRest HDFS
stopServiceViaRest YARN
stopServiceViaRest MAPREDUCE2
stopServiceViaRest OOZIE

echo "Download and unzip WebWasb and Hue while services are STOPPING"
downloadAndUnzipWebWasb
downloadAndUnzipHue

startServiceViaRest YARN
startServiceViaRest MAPREDUCE2
startServiceViaRest OOZIE
startServiceViaRest HDFS

setupWebWasbService
setupHueService

#---END MAIN PROGRAM---

