#!/usr/bin/env bash

# This is a modified version of the script published by Microsoft here https://hdiconfigactions.blob.core.windows.net/rconfigactionv02/r-installer-v02.ps1
# The original script seems to only work with HDInsight R Server clusters, the modifications make it work with the free version of R

# Import the helper method module.
wget -O /tmp/HDInsightUtilities-v01.sh -q https://hdiconfigactions.blob.core.windows.net/linuxconfigactionmodulev01/HDInsightUtilities-v01.sh && source /tmp/HDInsightUtilities-v01.sh && rm -f /tmp/HDInsightUtilities-v01.sh

# In case R is installed, exit.
if [ -e /usr/bin/R ]; then
    echo "R is already installed, exiting ..."
    
	# Vijay Thakorlal - 8th June 2017 modified MSFT R installation path to remove 8.x and replace with 3.3 
    #Check for SparkR installation libraries
    if [ -d /usr/lib64/microsoft-r/3.3/lib64/R/library/ ]; then
        echo "R was installed as part of cluster image, adding additional libraries and setting necessary environment variables."
        download_file https://hdiconfigactions.blob.core.windows.net/linuxrconfigactionv01/r-site-library.tgz /tmp/r-site-library.tgz
        tar -xf /tmp/r-site-library.tgz -C /usr/lib64/microsoft-r/3.3/lib64/R/library/ --skip-old-files
        rm -f /tmp/r-site-library.tgz 
        
        hadoopStreamingJar=$(find /usr/hdp/ | grep hadoop-mapreduce/hadoop-streaming-.*.jar | head -n 1)
        hadoopcmd=`grep -F "HADOOP_CMD" /etc/environment`
        hadoopstreaming=`grep -F "HADOOP_STREAMING" /etc/environment`
        ldlibrarypath=`grep -F "LD_LIBRARY_PATH" /etc/environment`
        isldlibrarypathpresent=`echo $ldlibrarypath | grep -F "/usr/lib/jvm/java-7-openjdk-amd64/jre/lib/amd64/server"`
        if [ ! -z "$hadoopStreamingJar" ]; then
            # Add in necessary environment values.
            if [ -z "$hadoopcmd" ]; then
                echo "HADOOP_CMD=/usr/bin/hadoop" | sudo tee -a /etc/environment
            fi
            if [ -z "$hadoopstreaming" ]; then
                echo "HADOOP_STREAMING=$hadoopStreamingJar" | sudo tee -a /etc/environment
            fi
            if [ -z "$isldlibrarypathpresent" ]; then
                echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/lib/jvm/java-7-openjdk-amd64/jre/lib/amd64/server" | sudo tee -a /etc/environment
            fi
        fi

    fi
	
	sudo /usr/bin/R CMD javareconf
    exit 0
fi

# Install the latest version of R.
OS_VERSION=$(lsb_release -sr)
if [[ $OS_VERSION == 14* ]]; then
    echo "OS verion is $OS_VERSION. Using R Trusty Tahr release."
    echo "deb http://cran.rstudio.com/bin/linux/ubuntu trusty/" | tee -a /etc/apt/sources.list
elif [[ $OS_VERSION == 16* ]]; then
    echo "OS verion is $OS_VERSION. Using Xenial Tahr release."
    echo "deb http://cran.rstudio.com/bin/linux/ubuntu xenial/" | tee -a /etc/apt/sources.list
else
    echo "OS verion is $OS_VERSION. Using R Precise Pangolin release."
    echo "deb http://cran.rstudio.com/bin/linux/ubuntu precise/" | tee -a /etc/apt/sources.list
fi

apt-key adv --keyserver keyserver.ubuntu.com --recv-keys E084DAB9
add-apt-repository -y ppa:marutter/rdev
apt-get -y --force-yes update
apt-get -y --force-yes install r-base r-base-dev

if [ ! -e /usr/bin/R -o ! -e /usr/local/lib/R/site-library ]; then
    echo "Either /usr/bin/R or /usr/local/lib/R/site-library does not exist. Retry installing R"
    sleep 15
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys E084DAB9
    add-apt-repository -y ppa:marutter/rdev
    apt-get -y --force-yes update
    apt-get -y --force-yes install r-base r-base-dev
fi

if [ ! -e /usr/bin/R -o ! -e /usr/local/lib/R/site-library ]; then
    echo "Either /usr/bin/R or /usr/local/lib/R/site-library does not exist after retry. Exiting..."
    exit 1
fi

# Download packages.
download_file https://hdiconfigactions.blob.core.windows.net/linuxrconfigactionv01/r-site-library.tgz /tmp/r-site-library.tgz
untar_file /tmp/r-site-library.tgz /usr/local/lib/R/site-library/

# Remove temporary files.
rm -f /tmp/r-site-library.tgz 

hadoopStreamingJar=$(find /usr/hdp/ | grep hadoop-mapreduce/hadoop-streaming-.*.jar | head -n 1)

if [ -z "$hadoopStreamingJar" ]; then
    echo "Cannot find hadoop-streaming jar file. Exiting..."
    exit 1
fi

# Add in necessary environment values.
echo "HADOOP_CMD=/usr/bin/hadoop" | sudo tee -a /etc/environment
echo "HADOOP_STREAMING=$hadoopStreamingJar" | sudo tee -a /etc/environment
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/lib/jvm/java-7-openjdk-amd64/jre/lib/amd64/server" | sudo tee -a /etc/environment


sudo /usr/bin/R CMD javareconf