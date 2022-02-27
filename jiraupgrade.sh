#!/bin/bash
### JIRA UPGRADE


###Put ourselves in a screen session
if [[ $STY = "" ]]; then
	echo "Running ourself in a screen session."
	screen -S jiraupgrade "$0"
	exit
fi


VERSION=
SERVICENAME=
TICKET=


read -p "Ticket Number? " TICKET
read -p "Target Version? " VERSION
echo ""

## Parse the service name, prompt if this fails
echo "Finding active service name..."
if [[ $(systemctl|grep j2ee | wc -l) -eq 1 ]] ; then
	SERVICENAME=$(systemctl|grep j2ee|awk '{print $1}')
	echo "Using $SERVICENAME as the active service."
else
	echo "Unable to automatically determine service, what should we be using?"
	echo ""
	systemctl |grep j2ee
	echo ""
	read -p "Service name?" SERVICENAME
	echo ""
fi



##Collect info we will need

FILEOWNER=$(stat -c '%U' data/dbconfig.xml)
echo "Files are owned by $FILEOWNER"


DATABASECONNECTION=$(awk -F '[<>]' '/url/{print $3}' data/dbconfig.xml)
DATABASE=$(awk -F/ '{print $4}' <<< $DATABASECONNECTION)
echo "Using $DATABASE"
echo ""


echo "1) Prep"
echo "2) Run the Sched"
echo "3) ROLLBACK"
echo ""
read -n 1 -p 'Well? ' CHOICE
echo ""



if [ $CHOICE = "1" ] ; then


###PREP

### Check for enough space to do the work
DATADIRSIZE=$(du -sk data/ --exclude={data/attachments,analytics-logs,backup,caches,*.bak,tmp,temp,export,import,log,logs,plugins/.??*,CACHECLEAR*,cache-clear*,cacheclear*}|awk {'print $1'})
FREESPACE=$(df -k . --output=avail|tail -1)

if [[ $FREESPACE -lt $(( 2 * $DATADIRSIZE )) ]] ; then
	echo "Not enough free space, aborting."
	exit 1
else
	echo "Enough space found, proceeding."
fi

##Set up the files

# Clone the data, no attachments
echo "Copying data..."
time rsync -aHS --exclude={data/attachments,analytics-logs,backup,caches,*.bak,tmp,temp,export,import,log,logs,plugins/.??*,CACHECLEAR*,cache-clear*,cacheclear*} data/ data-$VERSION/ || exit 1
ln -s data-$VERSION next.data || exit 1


# Get the application
echo "Fetching and installing the application..."
wget https://www.atlassian.com/software/jira/downloads/binary/atlassian-jira-software-$VERSION.tar.gz || exit 1
tar xzf atlassian-jira-software-$VERSION.tar.gz || exit 1
ln -s atlassian-jira-software-$VERSION-standalone next || exit 1


## The fancy diffs
for FILEPAIR in "current/bin/setenv.sh next/bin/setenv.sh" "current/conf/server.xml next/conf/server.xml" "current/atlassian-jira/WEB-INF/classes/seraph-config.xml next/atlassian-jira/WEB-INF/classes/seraph-config.xml" "current/atlassian-jira/WEB-INF/classes/jira-application.properties next/atlassian-jira/WEB-INF/classes/jira-application.properties" "current/atlassian-jira/WEB-INF/urlrewrite.xml next/atlassian-jira/WEB-INF/urlrewrite.xml" "current/atlassian-jira/WEB-INF/classes/crowd.properties next/atlassian-jira/WEB-INF/classes/crowd.properties"
	do 
		echo "Checking $FILEPAIR"
			if [[ $(sdiff -BWsi $FILEPAIR) != "" ]]; then
					sdiff -BWsi $FILEPAIR
					echo ""
					echo "^^^^^^^^^^"
					echo ""
					echo "What to do?"
					echo "1\) Copy over"
					echo "2\) Run vimdiff"
					echo ""
					read -n 1 -p 'Well? ' CHOICE
					echo ""
					if [ $CHOICE = "1" ] ; then
						cp -vi $FILEPAIR
					elif [ $CHOICE = "2" ] ; then
						vimdiff $FILEPAIR
					else
						echo "Invalid input, breaking, please do diffs manually"
						break
					fi  

			else
				echo "Files match"

			fi
	done

#sdiff -BWsi {current,next}/bin/setenv.sh 
#sdiff -BWsi {current,next}/conf/server.xml 
#sdiff -BWsi {current,next}/atlassian-jira/WEB-INF/classes/seraph-config.xml 
#sdiff -BWsi {current,next}/atlassian-jira/WEB-INF/classes/jira-application.properties 
#sdiff -BWsi {current,next}/atlassian-jira/WEB-INF/urlrewrite.xml 
#sdiff -BWsi {current,next}/atlassian-jira/WEB-INF/classes/crowd.properties



chown -R root:root next/ && chown -R $FILEOWNER. next/{logs,temp,webapps,work,conf} && chown -R $FILEOWNER. next.data/ || exit 1
echo "Permissions set"

echo "checking for okta. deal with it if you find anything"
find current/ | grep okta


echo "Make sure the atlassian recommended settings are in..."
grep -xF 'upgrade.reindex.allowed=false' data/jira-config.properties || echo 'upgrade.reindex.allowed=false' >> data/jira-config.properties
grep -xF 'jira.autoexport=false' data/jira-config.properties || echo 'jira.autoexport=false' >> data/jira-config.properties


echo "Prep completed!"
exit


elif [ $CHOICE = "2" ] ; then

### SCHED

echo "Stopping the service..."
systemctl stop $SERVICENAME

##Move files
echo "Moving the files..."
time rsync -aHS --exclude={data/attachments,analytics-logs,backup,caches,*.bak,tmp,temp,export,import,log,logs,plugins/.??*,CACHECLEAR*,cache-clear*,cacheclear*} --delete data/ next.data/ || exit 1
mv -v data/data/attachments next.data/data/ || exit 1
mv -v current prev && mv -v next current || exit 1
mv -v data prev.data && mv -v next.data data || exit 1

echo "Dumping backup copy of the database..."
if [[ "$DATABASECONNECTION" == *"localhost"* ]]; then
	## Database Dump
	su - postgres -c "mkdir -p /var/lib/pgsql/backups/other/" && time su - postgres -c "pg_dump -O $DATABASE | gzip > /var/lib/pgsql/backups/other/$DATABASE-PRE-$TICKET.dmp.gz"
	echo "checking to be sure backup was created"
	ls -al /var/lib/pgsql/backups/other/$DATABASE-PRE-$TICKET.dmp.gz

else
	echo "Database is not local, check at $DATABASECONNECTION"
	echo "Please run the following there"
	echo "su - postgres -c \"pg_dump -O $DATABASE | gzip > /var/lib/pgsql/backups/other/$DATABASE-PRE-$TICKET.dmp.gz\""
	read -p "Press any key to resume ..."
fi


## Start and watch
systemctl start $SERVICENAME && tail -F data/log/atlassian-jira.log

exit

elif [ $CHOICE = "3" ] ; then

###  ROLLBACK

systemctl stop $SERVICENAME


## Reimport database
# Collect database creds
DATABASEUSERNAME=$(awk -F '[<>]' '/username/{print $3}' data/dbconfig.xml)
DATABASEPASSWORD=$(awk -F '[<>]' '/password/{print $3}' data/dbconfig.xml)


## check if database is local

if [[ "$DATABASECONNECTION" == *"localhost"* ]]; then
	## Restore database
	echo "Re-creating and restoring database..."
	su - postgres -p -c "dropdb $DATABASE"
	su - postgres -p -c "createdb -E UNICODE T template0 -O $DATABASEUSERNAME $DATABASE"

	export PGPASSWORD=$DATABASEPASSWORD
	time su - postgres -p -c "zcat /var/lib/pgsql/backups/other/$DATABASE-PRE-$TICKET.dmp.gz | psql -U $DATABASEUSERNAME $DATABASE"
else
	echo "Database is not local, check at $DATABASECONNECTION"
	echo "Please restore database there, will continue after a pause"
	read -p "Press any key to resume ..."
fi

## Restore files
mv -v data/attachments prev.data/ || exit 1
mv -v current failed-$TICKET && mv -v data failed.data-$TICKET || exit 1
mv -v prev current && mv -v prev.data data || exit 1


## Start and watch
systemctl start $SERVICENAME && tail -F data/logs/atlassian-confluence.log

exit
fi
