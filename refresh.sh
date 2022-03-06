#!/bin/bash
### Script to automate refreshing Jira/Confluence instances, following the guide at https://wiki.contegix.com/display/~cbilyeu/Refreshes
## Written by lmiller


###Need to check for and install PGSQL tools 11, and refactor remote calls to just pull the pg_dump locally instead of doing it via piped ssh commands

##Collect info we will need

# Define getopt handling
TEMP=$( getopt -o t:s:d:a:r:p:h --long ticket:,service:,database:,app:,remote:,remotepath:,help -n "$( basename "$0" )" -- "$@" )
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
        -r|--remote)
			case "$2" in
			*)
				REMOTE=$2
				echo "Source server is $REMOTE."
				shift 2
				;;
			esac
			;;
        -p|--remotepath)
			case "$2" in
			*)
				REMOTEPATH=$2
				echo "Source server is $REMOTEPATH."
				shift 2
				;;
			esac
			;;
        ##  Help text, could you tell?
		-h|--help)
			printf "write new help eventually"
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
		SHAREDOPTS=$( echo --exclude={analytics-logs,backup,caches,*.bak,tmp,temp,export,import,log,logs,plugins/.??*,CACHECLEAR*,cache-clear*,cacheclear*} )
	elif [[ -f data/dbconfig.xml ]] ; then
		APP=jira
		CONFIGFILE=data/dbconfig.xml
		APPLOG=data/log/atlassian-jira.log
		echo "We are working with Jira."
		FILEOWNER=$( stat -c '%U' data/dbconfig.xml )
		echo "Files are owned by $FILEOWNER"
		SHAREDOPTS=$( echo --exclude={analytics-logs,backup,caches,*.bak,tmp,temp,export,import,log,logs,plugins/.??*,CACHECLEAR*,cache-clear*,cacheclear*} )
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
		while [[ $SERVICENAME == "" ]] ; do
			echo "Unable to automatically determine service, what should we be using?"
			echo ""
			systemctl |grep j2ee
			echo ""
			read -r -p "Service name? " SERVICENAME
			echo ""
		done
	fi
fi

while [[ "$TICKET" == "" ]] ; do
	read -r -p "Ticket Number? " TICKET
done

while [[ "$REMOTE" == "" ]] ; do
	read -r -p "Source server? " REMOTE
done

while [[ "$REMOTEPATH" == "" ]] ; do
	read -r -p "Source server path to application? " REMOTEPATH
done

echo ""

## Check to see if source server is keyed for SSH
if ssh  -o PasswordAuthentication=no "$REMOTE" exit; then
    echo "Source server keyed properly..."
else
    echo "Please key remote server so SSH commands can work!"
    exit 1
fi


###Put ourselves in a screen session
if [[ $STY = "" ]]; then
	echo "Running ourself in a screen session."
	screen -S "$( basename "$0" .sh)" -L $0 --ticket "$TICKET" --remote "$REMOTE" --app "$APP" --database "$DATABASE" --service "$SERVICENAME" --remotepath "$REMOTEPATH"
	printf "\n\n\n--------------------------- $( date +%FT%T ) $TICKET ---------------------\n\n\n" >> "$( basename "$0" )".$TICKET.log
	cat screenlog.? >> "$( basename "$0" .sh )".$TICKET.log
	rm screenlog.?
	exit
fi

echo "Working on ticket $TICKET"
echo "Upgrading $APP"
echo "Using database $DATABASE"
echo "Controlling service $SERVICENAME"
echo "Copying data from $REMOTE"
LOCALIPS=$( ip a |grep "inet "|awk -F'[ /]' '{print $6}' )
TARGETIP=$( dig +short $HOSTNAME )
if [[ "$LOCALIPS" == *"$TARGETIP"* ]] ; then
    LOCAL=true
    echo "Source data is on local server. Not pulling from remote."
else
    LOCAL=false
fi
echo ""
echo "Source data path is $REMOTEPATH"
echo ""
echo "Please verify the above before proceeding."
echo ""
echo ""

## Whats the job

echo "Which step are we executing?"
echo ""
echo "1) Refresh"
echo "2) ROLLBACK"
echo "X) Exit. or any key really."
echo ""
read -r -n 1 -p 'Well? ' CHOICE
echo ""

if [ "$CHOICE" = "1" ] ; then
    #########################
    ### TIME FOR WORK ######
    ########################

    ##Do we need to clean up from a previous upgrade?
    if [[ -e prev ]] ; then
        echo "Please cleanup after previous activity!"
        exit 1
    elif [[ -e prev.data ]] ; then
            echo "Please cleanup after previous activity!"
            exit 1
    fi


    ## Check for enough space to do the work
    echo "Checking for enough disk space for the upgrade..."
    if [[ "$LOCAL" == "false" ]] ; then
        DATADIRSIZE=$( ssh $REMOTE du -sk "$SHAREDOPTS" $REMOTEPATH/data/ | awk '{print $1}' )
        FREESPACE=$( df -k . --output=avail | tail -1 )
    elif [[ "$LOCAL" == "true" ]] ; then
        DATADIRSIZE=$( du -sk "$SHAREDOPTS" data/ | awk '{print $1}' )
        FREESPACE=$( df -k . --output=avail | tail -1 )
    fi

    if [[ $FREESPACE -lt $(( 2 * $DATADIRSIZE )) ]] ; then
        echo "Not enough free space, aborting."
        exit 1
    else
        echo "Enough space found, proceeding."
    fi

    ## Prep, create restore data

    echo "Stopping service..."
    systemctl stop $SERVICENAME
    if [[ "$LOCAL" == "true" ]] ; then
        echo "Dumping local database $DATABASE in /var/lib/pgsql/backups/other/"
        if [[ ! -d /var/lib/pgsql/backups/other/ ]] ; then
            mkdir -p /var/lib/pgsql/backups/other/
        fi
        su - postgres -c "pg_dump -O $DATABASE | gzip > /var/lib/pgsql/backups/other/$DATABASE-PRE-$TICKET.dmp.gz"
        cp -av data/confluence.cfg.xml confluence.cfg.xml-CURRENT
    elif [[ "$LOCAL" == "false" ]] ; then
        echo "Dumping local database $DATABASE in /var/lib/pgsql/backups/other/"
        if [[ ! -d /var/lib/pgsql/backups/other/ ]] ; then
            ssh $REMOTE 'mkdir -p /var/lib/pgsql/backups/other/'
        fi
        ssh $REMOTE 'su - postgres -c "pg_dump -O $DATABASE | gzip > /var/lib/pgsql/backups/other/$DATABASE-PRE-$TICKET.dmp.gz"'
        ssh $REMOTE 'cp -av data/confluence.cfg.xml confluence.cfg.xml-CURRENT'
    fi

    ##Set up the files

    # Clone the data
    echo "Copying data dir"
    if [[ "$LOCAL" == "false" ]] ; then
        time rsync -aHS "$SHAREDOPTS" $REMOTE:$REMOTEPATH/data/ data-REFRESH-"$TICKET"/ || { echo "Failed to rsync remote data." ; exit 1; }
    elif [[ "$LOCAL" == "true" ]] ; then
        time rsync -aHS "$SHAREDOPTS" $REMOTEPATH/data/ data-REFRESH-"$TICKET"/ || { echo "Failed to rsync data." ; exit 1; }
    fi
    ln -s data-REFRESH-"$TICKET" next.data || { echo "Linking the next data/ dir failed." ; read -r -n 1 -p "Press any key to resume ..."; }

    ## Parse out old settings
    if [[ $SOURCEDATABASE == "" ]] ; then
        SOURCEDATABASECONNECTION=$( awk -F '[<>]' '/url/{print $3}' data-REFRESH-"$TICKET"/$( basename $CONFIGFILE ) )
        SOURCEDATABASE=$( awk -F '[/?]' '{print $4}' <<< "$SOURCEDATABASECONNECTION" )
        #SOURCEDATABASEPASSWORD=$(awk -F '[<>]' '/password/{print $3}' data-REFRESH-"$TICKET"/$( basename $CONFIGFILE ) )
        echo "Using $SOURCEDATABASE as source database..."
        echo ""
    fi

    echo "Copying database from source..."
    if [[ "$LOCAL" == "false" ]] ; then
        ssh $REMOTE 'su - postgres -c "pg_dump -O $SOURCEDATABASE | gzip > /var/lib/pgsql/backups/other/$SOURCEDATABASE-FOR-$TICKET.dmp.gz"'
        ssh $REMOTE 'ls -alh /var/lib/pgsql/backups/other/'
        read -r -n 1 -p "Press any key to resume ..."
    elif [[ "$LOCAL" == "true" ]] ; then
        su - postgres -c "pg_dump -O $SOURCEDATABASE | gzip > /var/lib/pgsql/backups/other/$SOURCEDATABASE-FOR-$TICKET.dmp.gz"
        ls -alh /var/lib/pgsql/backups/other/
        read -r -n 1 -p "Press any key to resume ..."
    fi
    time rsync -aHS $REMOTE:/var/lib/pgsql/backups/other/$SOURCEDATABASE-FOR-$TICKET.dmp.gz $PWD


    # Collect database creds
    DATABASEUSERNAME=$(awk -F '[<>]' '/username/{print $3}' $CONFIGFILE)
    DATABASEPASSWORD=$(awk -F '[<>]' '/password/{print $3}' $CONFIGFILE)


    echo "Re-creating and restoring database..."
    su - postgres -p -c "dropdb $DATABASE" || { echo "Failed to drop existing database" ; exit 1; }
    su - postgres -p -c "createdb -E UNICODE -O $DATABASEUSERNAME $DATABASE" || { echo "Database creation failed"; exit 1; }

    export PGPASSWORD=$DATABASEPASSWORD
    time su - postgres -p -c "zcat /var/lib/pgsql/backups/other/$DATABASE-PRE-$TICKET.dmp.gz | psql -U $DATABASEUSERNAME $DATABASE" || { echo "Database import failed"; exit 1; }

    # move config files around
    mv -v data-REFRESH-$TICKET/confluence.cfg.xml confluence.cfg.xml-PROD
    mv -v confluence.cfg.xml-CURRENT data-REFRESH-$TICKET/confluence.cfg.xml

    ## The fancy diffs
    for FILEPAIR in "confluence.cfg.xml-PROD data-REFRESH-$TICKET/confluence.cfg.xml"
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

    ## Fix Permissions
    echo "Setting permissions..."
    chown -R $FILEOWNER: data-REFRESH-$TICKET
    echo "Permissions set"

    echo "Starting service!"
    systemctl start $SERVICENAME
    tail -F $APPLOG


    echo "Refresh completed!"
    exit
    
elif [[ "$CHOICE" = "2" ]] ; then

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
    if [[ "$LOCAL" == "true" ]] ; then
        ## Restore database
        echo "Re-creating and restoring database..."
        su - postgres -p -c "dropdb $DATABASE" || { echo "Failed to drop existing database" ; exit 1; }
        su - postgres -p -c "createdb -E UNICODE -O $DATABASEUSERNAME $DATABASE" || { echo "Database creation failed"; exit 1; }
        export PGPASSWORD=$DATABASEPASSWORD
        time su - postgres -p -c "zcat /var/lib/pgsql/backups/other/$DATABASE-PRE-$TICKET.dmp.gz | psql -U $DATABASEUSERNAME $DATABASE" || { echo "Database import failed"; exit 1; }
    elif [[ "$LOCAL" == "true" ]] ; then
        echo "Re-creating and restoring database..."
        ssh $REMOTE 'su - postgres -p -c "dropdb $DATABASE"' || { echo "Failed to drop existing database" ; exit 1; }
        ssh $REMOTE 'su - postgres -p -c "createdb -E UNICODE -O $DATABASEUSERNAME $DATABASE"' || { echo "Database creation failed"; exit 1; }
        ssh $REMOTE 'PGPASSWORD=$DATABASEPASSWORD; time su - postgres -p -c "zcat /var/lib/pgsql/backups/other/$DATABASE-PRE-$TICKET.dmp.gz | psql -U $DATABASEUSERNAME $DATABASE"' || { echo "Database import failed"; exit 1; }
    fi

    ## Restore files
    mv -v data failed.data-"$TICKET" || { echo "Failed to move symlinks to failed targets..." ; exit 1; }
    mv -v prev.data data || { echo "Failed to restore original symlinks..." ; exit 1; }

    ## Start and watch
    systemctl start "$SERVICENAME" && tail -F $APPLOG

    exit
else
	echo "Exiting!"
	exit 1
fi
