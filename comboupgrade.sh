#!/bin/bash
### Script to automate upgrading Jira/Confluence instances, following the guides at https://wiki.contegix.com/display/~cbilyeu/Upgrading+Jira and https://wiki.contegix.com/display/~cbilyeu/Upgrading+Confluence
## Written by lmiller


##Collect info we will need

# Define getopt handling
TEMP=$( getopt -o t:v:s:d:a:h --long ticket:,version:,service:,database:,app:,help -n "$( basename "$0" )" -- "$@" )
eval set -- "$TEMP"

## getopt cases - only defining variables
while true
do
	case "$1" in
		-t|--ticket)
			case "$2" in
			*)
				TICKET=$2
				echo "Using $TICKET"
				shift 2
				;;
			esac
			;;
		-v|--version)
			case "$2" in
			*)
				VERSION=$2
				echo "Targetting version $VERSION"
				shift 2
				;;
			esac
			;;
		-s|--service)
			case "$2" in
			*)
				SERVICENAME=$2
				echo "Controlling the $SERVICENAME service"
				shift 2
				;;
			esac
			;;
		-d|--database)
			case "$2" in
			*)
				DATABASE=$2
				echo "Using the $DATABASE database"
				shift 2
				;;
			esac
			;;
		-a|--app)
			case "$2" in
			jira)
				APP=$2
				echo "Targetting $APP"
				shift 2
				;;
			confluence)
				APP=$2
				echo "Targetting $APP"
				shift 2
				;;
			*)
				echo "Please select a valid app: jira or confluence"
				exit 1
				;;
			esac
			;;


##  Help text, could you tell?
		-h|--help)
			printf "\n Script to automagically upgrade Jira or Confluence. Just run it and it will prompt for what it can't detect.\n\n    It takes the following args, which override autodetected settings:\n\t -v/--version\tTarget version, ie 7.14.12\n\t -a/--app\tjira/confluence\n\t -d/--database\tName of the database\n\t -s/--service\tName of the systemd service the app is running under\n\t -t/--ticket\tTicket number this is tracked under\n\n"
			exit 0
			;;
			
## Define blank as no more opts
		--) shift ; break ;;
	esac
done

if [[ $APP == "" ]] ; then
	# What are we working with?
	echo "Detecting which app we are using..."
	if [[ -f data/confluence.cfg.xml ]] ; then
		APP=confluence
		CONFIGFILE=data/confluence.cfg.xml
		APPLOG=data/logs/atlassian-confluence.log
		echo "We are working with Confluence."
		FILEOWNER=$( stat -c '%U' data/confluence.cfg.xml )
		echo "Files are owned by $FILEOWNER"
		SHAREDOPTS=$( echo --exclude={attachments,bundled-*,plugins-*,logs,temp,backups,clear-cache,cacheclear,import,export,backup,recovery,webresource-temp} )
	elif [[ -f data/dbconfig.xml ]] ; then
		APP=jira
		CONFIGFILE=data/dbconfig.xml
		APPLOG=data/log/atlassian-jira.log
		echo "We are working with Jira."
		FILEOWNER=$( stat -c '%U' data/dbconfig.xml )
		echo "Files are owned by $FILEOWNER"
		SHAREDOPTS=$( echo --exclude={data/attachments,analytics-logs,backup,caches,*.bak,tmp,temp,export,import,log,logs,plugins/.??*,CACHECLEAR*,cache-clear*,cacheclear*} )
	else
		echo "No app install detected."
		exit 1
	fi
elif [[ $APP = "confluence" ]] ; then
	CONFIGFILE=data/confluence.cfg.xml
	APPLOG=data/logs/atlassian-confluence.log
	echo "We are working with Confluence."
	FILEOWNER=$( stat -c '%U' data/confluence.cfg.xml )
	echo "Files are owned by $FILEOWNER"
	SHAREDOPTS=$( echo --exclude={attachments,bundled-*,plugins-*,logs,temp,backups,clear-cache,cacheclear,import,export,backup,recovery,webresource-temp} )
elif [[ $APP = "jira" ]] ; then
	CONFIGFILE=data/dbconfig.xml
	APPLOG=data/log/atlassian-jira.log
	echo "We are working with Jira."
	FILEOWNER=$( stat -c '%U' data/dbconfig.xml )
	echo "Files are owned by $FILEOWNER"
	SHAREDOPTS=$( echo --exclude={data/attachments,analytics-logs,backup,caches,*.bak,tmp,temp,export,import,log,logs,plugins/.??*,CACHECLEAR*,cache-clear*,cacheclear*} )
else
	echo "Please choose \'jira\' or \'confluence\' for a valid app choice."
fi



if [[ $DATABASE == "" ]] ; then
	## Get database info needed
	DATABASECONNECTION=$( awk -F '[<>]' '/url/{print $3}' $CONFIGFILE )
	DATABASE=$( awk -F '[/?]' '{print $4}' <<< "$DATABASECONNECTION" )
	echo "Using $DATABASE as active database..."
	echo ""
fi

if [[ $SERVICENAME == "" ]] ; then
	## Parse the service name, prompt if this fails
	echo "Finding active service name..."
	if [[ $( systemctl | grep -c j2ee ) -eq 1 ]] ; then
		SERVICENAME=$( systemctl -al | grep j2ee | awk '{print $1}' )
		echo "Using $SERVICENAME as the active service."
	else
		echo "Unable to automatically determine service, what should we be using?"
		echo ""
		systemctl |grep j2ee
		echo ""
		read -r -p "Service name? " SERVICENAME
		echo ""
	fi
fi

if [[ "$TICKET" == "" ]] ; then
	read -r -p "Ticket Number? " TICKET
fi

if [[ "$VERSION" == "" ]] ; then
	read -r -p "Target Version? " VERSION
fi

echo ""

###Put ourselves in a screen session
if [[ $STY = "" ]]; then
	echo "Running ourself in a screen session."
	screen -S "$( basename "$0" .sh)" -L $0 --ticket "$TICKET" --version "$VERSION" --app "$APP" --database "$DATABASE" --service "$SERVICENAME"
	printf "\n\n\n--------------------------- $( date +%FT%T ) $TICKET ---------------------\n\n\n" >> "$( basename "$0" )".$TICKET.log
	cat screenlog.? >> "$( basename "$0" .sh )".$TICKET.log
	rm screenlog.?
	exit
fi

echo "Working on ticket $TICKET"
echo "Upgrading $APP"
echo "Using database $DATABASE"
echo "Controlling service $SERVICENAME"
echo "Targetting version $VERSION"
echo ""
echo "Please verify the above before proceeding."
echo ""
echo ""

## Whats the job

echo "Which step are we executing?"
echo ""
echo "1) Prep"
echo "2) Run the Sched"
echo "3) ROLLBACK"
echo "X) Exit. or any key really."
echo ""
read -r -n 1 -p 'Well? ' CHOICE
echo ""


if [ "$CHOICE" = "1" ] ; then

###############
### PREP ######
###############

##Do we need to clean up from a previous upgrade?
if [[ -e prev ]] ; then
	echo "Please cleanup after previous upgrade!"
	exit 1
elif [[ -e prev.data ]] ; then
        echo "Please cleanup after previous upgrade!"
        exit 1
fi


## Check for enough space to do the work
echo "Checking for enough disk space for the upgrade..."
DATADIRSIZE=$( du -sk "$SHAREDOPTS" data/ | awk '{print $1}' )
FREESPACE=$( df -k . --output=avail | tail -1 )

if [[ $FREESPACE -lt $(( 2 * $DATADIRSIZE )) ]] ; then
	echo "Not enough free space, aborting."
	exit 1
else
	echo "Enough space found, proceeding."
fi

##Set up the files

# Clone the data, no attachments
echo "Copying data dir"
time rsync -aHS "$SHAREDOPTS" data/ data-"$VERSION"/ || { echo "Failed to rsync data." ; exit 1; }
ln -s data-"$VERSION" next.data || { echo "Linking the next data/ dir failed." ; read -r -n 1 -p "Press any key to resume ..."; }


## The fancy diffs
echo "Checking for changes to config files..."
if [[ $APP = confluence ]] ; then
	echo "Fetching and installing the app"
	wget --progress=dot:mega https://www.atlassian.com/software/confluence/downloads/binary/atlassian-confluence-"$VERSION".tar.gz -O atlassian-confluence-"$VERSION".tar.gz || { echo "Download failed" ; exit 1; }
	tar xzf atlassian-confluence-"$VERSION".tar.gz || { echo "Extracting failed..." ; exit 1; }
	ln -s atlassian-confluence-"$VERSION" next || { echo "Linking the next current/ dir failed" ; read -r -n 1 -p "Press any key to continue ..."; }
	rm atlassian-confluence-"$VERSION".tar.gz

	for FILEPAIR in 'data/confluence.cfg.xml next.data/confluence.cfg.xml' 'current/bin/setenv.sh next/bin/setenv.sh' 'current/conf/server.xml next/conf/server.xml' 'current/conf/web.xml next/conf/web.xml' 'current/confluence/WEB-INF/classes/confluence-init.properties next/confluence/WEB-INF/classes/confluence-init.properties' 'current/confluence/WEB-INF/classes/seraph-config.xml next/confluence/WEB-INF/classes/seraph-config.xml' 'current/confluence/WEB-INF/classes/crowd.properties next/confluence/WEB-INF/classes/crowd.properties' 'current/confluence/WEB-INF/classes/okta-config-confluence.xml next/confluence/WEB-INF/classes/okta-config-confluence.xml'
		do 
			echo "Checking $FILEPAIR"
				if [[ "$(sdiff -BWsi $FILEPAIR)" != "" ]]; then
					sdiff -BWsi $FILEPAIR
					echo ""
					echo "^^^^^^^^^^"
					echo ""
					echo "What to do?"
					echo "1\) Copy over"
					echo "2\) Run vimdiff"
					echo ""
					read -r -n 1 -p 'Well? ' CHOICE
					echo ""
				if [ "$CHOICE" = "1" ] ; then
					cp -vi $FILEPAIR
				elif [ "$CHOICE" = "2" ] ; then
					vimdiff $FILEPAIR
				else
					echo "Invalid input, breaking, please do diffs manually"
					break
				fi  

		else
			echo "Files match"
		fi
	done
elif [[ $APP = jira ]] ; then
	echo "Fetching and installing the app"
	wget --progress=dot:mega https://www.atlassian.com/software/jira/downloads/binary/atlassian-jira-software-$VERSION.tar.gz -O atlassian-jira-software-$VERSION.tar.gz || { echo "Download failed" ; exit 1; }
	tar xzf atlassian-jira-software-$VERSION.tar.gz || { echo "Extracting failed..." ; exit 1; }
	ln -s atlassian-jira-software-$VERSION-standalone next || { echo "Linking the next current/ dir failed"; read -r -n 1 -p "Press any key to continue ..."; }
	rm atlassian-jira-software-$VERSION.tar.gz

	for FILEPAIR in "current/bin/setenv.sh next/bin/setenv.sh" "current/conf/server.xml next/conf/server.xml" "current/atlassian-jira/WEB-INF/classes/seraph-config.xml next/atlassian-jira/WEB-INF/classes/seraph-config.xml" "current/atlassian-jira/WEB-INF/classes/jira-application.properties next/atlassian-jira/WEB-INF/classes/jira-application.properties" "current/atlassian-jira/WEB-INF/urlrewrite.xml next/atlassian-jira/WEB-INF/urlrewrite.xml" "current/atlassian-jira/WEB-INF/classes/crowd.properties next/atlassian-jira/WEB-INF/classes/crowd.properties"
		do 
			echo "Checking $FILEPAIR"
				if [[ $( sdiff -BWsi $FILEPAIR ) != "" ]]; then
					sdiff -BWsi $FILEPAIR
					echo ""
					echo "^^^^^^^^^^"
					echo ""
					echo "What to do?"
					echo "1\) Copy over"
					echo "2\) Run vimdiff"
					echo ""
					read -r -n 1 -p 'Well? ' CHOICE
					echo ""
				if [ "$CHOICE" = "1" ] ; then
					cp -vi $FILEPAIR
				elif [ "$CHOICE" = "2" ] ; then
					vimdiff $FILEPAIR
				else
					echo "Invalid input, breaking, please do diffs manually"
					break
				fi  

			else
				echo "Files match"
			fi
	done
fi

## Fix Permissions
echo "Setting permissions..."
chown -R root:root next/ && chown -R "$FILEOWNER". next/{conf,logs,temp,webapps,work} && chown -R "$FILEOWNER". next.data/ || { echo "Failed to set permissions" ; exit 1; }
echo "Permissions set"

## This part of the guide never found anything in my experience, putting in anyway
if [[ $APP = confluence ]] ; then
	echo "Copying okta, check manually"
	cp -vn current/confluence/WEB-INF/lib/okta-confluence-*.jar next/confluence/WEB-INF/lib/
elif [[ $APP = jira ]] ; then
	echo "Checking for okta. Deal with it if you find anything."
	find current/ | grep okta
	echo ""
	echo ""
	echo "Make sure the atlassian recommended settings are in..."
	grep -xF 'upgrade.reindex.allowed=false' data/jira-config.properties || echo 'upgrade.reindex.allowed=false' >> data/jira-config.properties
	grep -xF 'jira.autoexport=false' data/jira-config.properties || echo 'jira.autoexport=false' >> data/jira-config.properties
fi

echo "Prep completed!"
exit

elif [ "$CHOICE" = "2" ] ; then

##############
### SCHED ####
##############


echo "Stopping the service..."
systemctl stop "$SERVICENAME"

##Move files
echo "Moving the files..."
time rsync -aHS "$SHAREDOPTS" --delete data/ next.data/ || { echo "Failed to do final rsync." ; exit 1; }
mv -v data/attachments next.data/ || { echo "Failed to move attachments." ; exit 1; }
mv -v current prev && mv -v next current || { echo "Failed to update application symlinks." ; exit 1; }
mv -v data prev.data && mv -v next.data data || { echo "Failed to update data symlinks." ; exit 1; }

if [[ "$DATABASECONNECTION" == "" ]] ; then
	DATABASECONNECTION=$(awk -F '[<>]' '/url/{print $3}' $CONFIGFILE)
fi

echo "Dumping backup copy of the database..."
if [[ "$DATABASECONNECTION" == *"localhost"* ]]; then
	## Database Dump
	su - postgres -c "mkdir -p /var/lib/pgsql/backups/other/" 
	time su - postgres -c "pg_dump -O $DATABASE | gzip > /var/lib/pgsql/backups/other/$DATABASE-PRE-$TICKET.dmp.gz" || { echo "Database dump failed"; exit 1; }
	echo "checking to be sure backup was created"
	if [[ -f /var/lib/pgsql/backups/other/$DATABASE-PRE-$TICKET.dmp.gz ]] ; then
		ls -al /var/lib/pgsql/backups/other/"$DATABASE"-PRE-"$TICKET".dmp.gz
	else
		echo "Database not dumped!"
		exit 1
	fi
else
	echo "Database is not local, check at $DATABASECONNECTION"
	echo "Please run the following there"
	echo "su - postgres -c \"pg_dump -O $DATABASE | gzip > /var/lib/pgsql/backups/other/$DATABASE-PRE-$TICKET.dmp.gz\""
	read -r -n 1 -p "Press any key to continue ..."
fi

## Start and watch
systemctl start "$SERVICENAME" && tail -F $APPLOG
echo "Log into site, check integrity, health, upgrade plugins, reindex, do a log check, as applicable."
exit

elif [ "$CHOICE" = "3" ] ; then

##################
###  ROLLBACK ####
##################

systemctl stop "$SERVICENAME"

## Reimport database

# Collect database creds
DATABASEUSERNAME=$(awk -F '[<>]' '/username/{print $3}' $CONFIGFILE)
DATABASEPASSWORD=$(awk -F '[<>]' '/password/{print $3}' $CONFIGFILE)

if [[ "$DATABASECONNECTION" == "" ]] ; then
	DATABASECONNECTION=$(awk -F '[<>]' '/url/{print $3}' $CONFIGFILE)
fi

## check if database is local
if [[ "$DATABASECONNECTION" == *"localhost"* ]]; then
	## Restore database
	echo "Re-creating and restoring database..."
	su - postgres -p -c "dropdb $DATABASE" || echo "Failed to drop existing database" || exit 1
	su - postgres -p -c "createdb -E UNICODE -O $DATABASEUSERNAME $DATABASE" || { echo "Database creation failed"; exit 1; }

	export PGPASSWORD=$DATABASEPASSWORD
	time su - postgres -p -c "zcat /var/lib/pgsql/backups/other/$DATABASE-PRE-$TICKET.dmp.gz | psql -U $DATABASEUSERNAME $DATABASE" || { echo "Database import failed"; exit 1; }
else
	echo "Database is not local, check at $DATABASECONNECTION"
	echo "Please restore database there, will continue after a pause"
	read -r -n 1 -p "Press any key to continue ..."
fi

## Restore files
mv data/attachments prev.data/ || { echo "Failed to move attachments back..."; exit 1; }
mv current failed-"$TICKET" && mv data failed.data-"$TICKET" || { echo "Failed to move symlinks to failed targets..." ; exit 1; }
mv prev current && mv prev.data data || { echo "Failed to restore original symlinks..." ; exit 1; }

## Start and watch
systemctl start "$SERVICENAME" && tail -F $APPLOG

exit
else
	echo "Exiting!"
	exit 1
fi
